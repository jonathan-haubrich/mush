const std = @import("std");

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
