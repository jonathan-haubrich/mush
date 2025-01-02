const std = @import("std");
const win = std.os.windows;
const WinSocket = @import("winsocket.zig");

pub const RemoteTty = @This();
const Self = @This();

const CRLF = [_]u8{ std.ascii.control_code.cr, std.ascii.control_code.lf };
const CR = [_]u8{std.ascii.control_code.cr};
const CS_CURSOR_RIGHT = [_]u8{ std.ascii.control_code.esc, '[', 'C' };
const CS_CURSOR_LEFT = [_]u8{ std.ascii.control_code.esc, '[', 'D' };

pub const RemoteTtyError = error{
    InvalidInput,
};

allocator: std.mem.Allocator,
winsock: *WinSocket,
cursor: usize = 0,
buffer: std.ArrayList(u8),
// this is the current width of the command line
// this can differ from cursor if the user presses left/right for example
current_width: usize = 0,
max_width: usize = 0,

// TODO: Abstract the winsocket into a stream supporting reader/writer
pub fn init(winsock: *WinSocket, allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .winsock = winsock,
        .buffer = std.ArrayList(u8).init(allocator),
    };
}

fn reset_buffer(self: *Self) void {
    self.cursor = 0;
    self.current_width = 0;
    self.max_width = 0;
    self.buffer.clearRetainingCapacity();
}

fn append_input(self: *Self, c: u8) !void {
    if (self.buffer.capacity < self.cursor) {
        try self.buffer.resize(self.buffer.capacity * 2);
    }

    try self.buffer.insert(self.cursor, c);

    self.cursor += 1;
    self.current_width += 1;
    self.max_width = @max(self.current_width, self.max_width);
}

fn cursor_left(self: *Self) void {
    if (self.cursor > 0) {
        self.cursor -= 1;
    }
}

fn cursor_right(self: *Self) void {
    if (self.cursor < self.current_width) {
        self.cursor += 1;
    }
}

fn handle_esc(self: *Self) !void {
    // first check to see if we got an escape sequence or if the user just pressed escape
    // do so by recv'ing on a short timeout
    var next = self.winsock.recvOne(100) catch |err| {
        if (err == win.WaitForSingleObjectError.WaitTimeOut) {
            // we timed out so we assume the user pressed escape
            // treat this as user wanting to clear the line
            self.reset_buffer();
            std.debug.print("[handle_esc] returning from catch, reset_buffer\n", .{});

            return;
        }

        std.debug.print("[handle_esc] returning from catch, err\n", .{});
        return err;
    };

    std.debug.print("[handle_esc] got next: {any}\n", .{next});

    if ('[' == next) {
        // got a control sequence
        // only handle left and right for the moment
        next = try self.winsock.recvOne(null);
        std.debug.print("[handle_esc] got next (2): {any}\n", .{next});
        switch (next) {
            'C' => self.cursor_right(),
            'D' => self.cursor_left(),
            else => {
                std.debug.print("[handle_esc] Invalid input: {any}\n", .{next});
                return RemoteTtyError.InvalidInput;
            },
        }
    }
}

fn handle_del(self: *Self) !void {
    if (0 == self.cursor or 0 == self.buffer.items.len) {
        return;
    }

    _ = self.buffer.orderedRemove(self.cursor - 1);
    self.cursor -= 1;
    self.current_width -= 1;
}

fn print_buffer(self: *Self) !void {
    // clear line with number of necessary spaces
    _ = try self.winsock.send(@constCast(&CR));
    const spaces = try self.allocator.alloc(u8, self.max_width);
    defer self.allocator.free(spaces);
    @memset(spaces, ' ');
    _ = try self.winsock.send(spaces);

    // now print buffer
    _ = try self.winsock.send(@constCast(&CR));
    _ = try self.winsock.send(self.buffer.items[0..self.current_width]);

    // to get cursor in correct position we print a number of backspaces
    // the number is the difference between our current width and our cursor position
    if (self.current_width > self.cursor) {
        const backspaces = try self.allocator.alloc(u8, self.current_width - self.cursor);
        defer self.allocator.free(backspaces);
        @memset(backspaces, std.ascii.control_code.bs);
        _ = try self.winsock.send(backspaces);
    }
}

pub fn get_command_line(self: *Self) ![]u8 {
    // main function which will read and handle inputs
    // stops processing when a newline or carriage return is received

    input_loop: while (true) {
        const next = try self.winsock.recvOne(null);

        // handle keypress
        switch (next) {
            std.ascii.control_code.etx => std.process.exit(0),
            std.ascii.control_code.esc => try self.handle_esc(),
            std.ascii.control_code.del => try self.handle_del(),
            std.ascii.control_code.cr, std.ascii.control_code.lf => {
                _ = try self.winsock.send(@constCast(&CRLF));
                break :input_loop;
            },
            else => {
                if (std.ascii.isPrint(next)) {
                    try self.append_input(next);
                } else {
                    std.debug.print("[get_command_line] Invalid input: {any}\n", .{next});
                    return error.InvalidInput;
                }
            },
        }

        try self.print_buffer();
    }

    const ret = try self.allocator.dupe(u8, self.buffer.items[0..self.current_width]);
    self.reset_buffer();

    return ret;
}

pub fn deinit(self: *Self) void {
    self.buffer.clearAndFree();
}

fn test_tty() void {
    var address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 4444);
    var server = try address.listen(.{});

    var connection = try server.accept();

    const prompt = "> ";

    var buf: [1]u8 = undefined;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var cmdline = std.ArrayList(u8).init(allocator);

    _ = try connection.stream.writeAll(prompt);

    while (true) {
        const bytes_read = try connection.stream.read(&buf);

        if (bytes_read < 1) {
            std.debug.print("Remote end closed connection\n", .{});
            return;
        }

        std.debug.print("Read from remote: ", .{});

        switch (buf[0]) {
            std.ascii.control_code.etx => std.process.exit(0),
            std.ascii.control_code.esc => {
                std.debug.print("<ESC>", .{});
            },
            std.ascii.control_code.del => {
                std.debug.print("<DELETE>", .{});
                std.debug.print("cmdline.items.len: {d}", .{cmdline.items.len});
                if (cmdline.items.len > 0) {
                    _ = cmdline.pop();
                    std.debug.print("popped, cmdline.items.len: {d}", .{cmdline.items.len});
                    try std.fmt.format(connection.stream.writer(), "{c} {c}", .{ std.ascii.control_code.bs, std.ascii.control_code.bs });
                }
            },
            std.ascii.control_code.bs => {
                std.debug.print("<BACKSPACE>", .{});
                std.debug.print("cmdline.items.len: {d}", .{cmdline.items.len});
                if (cmdline.items.len > 0) {
                    _ = cmdline.pop();
                    try std.fmt.format(connection.stream.writer(), "{c} {c}", .{ std.ascii.control_code.bs, std.ascii.control_code.bs });
                }
            },
            std.ascii.control_code.cr => {
                std.debug.print("\\r", .{});
                _ = try connection.stream.writeAll("\r\n");
                try std.fmt.format(connection.stream.writer(), "Got command line: {s}\r\n", .{cmdline.items});
                cmdline.clearAndFree();
                _ = try connection.stream.writeAll(prompt);
            },
            std.ascii.control_code.ht => {
                std.debug.print("\\t", .{});
                try std.fmt.format(connection.stream.writer(), "{c}", .{buf[0]});
                try cmdline.append(buf[0]);
            },
            std.ascii.control_code.lf => {
                std.debug.print("\\n", .{});
                try std.fmt.format(connection.stream.writer(), "{c}", .{buf[0]});
                try cmdline.append(buf[0]);
            },
            ' ' => {
                std.debug.print("<SPACE>", .{});
                try std.fmt.format(connection.stream.writer(), "{c}", .{buf[0]});
                try cmdline.append(buf[0]);
            },
            else => {
                std.debug.print("<OTHER> {c} as hex: {}", .{ buf[0], std.fmt.fmtSliceHexLower(&buf) });
                try std.fmt.format(connection.stream.writer(), "{c}", .{buf[0]});
                try cmdline.append(buf[0]);
            },
        }

        std.debug.print("\n", .{});

        // echo back the character
        // _ = try connection.stream.write("\r");
        // _ = try connection.stream.writeAll(cmdline.items);
    }
}
