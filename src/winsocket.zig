const std = @import("std");
const win = std.os.windows;
const ws2_32 = win.ws2_32;

pub const WinSocket = @This();
const Self = @This();

const WinSocketError = error{
    InvalidState,
    SocketCreationFailed,
    ConnectFailed,
    RecvFailed,
    RecvTimeout,
    SendFailed,
};

pub const Error = WinSocketError;

const State = enum(u32) {
    STATE_DISCONNECTED = 0,
    STATE_CONNECTED,
};

address: std.net.Address,
state: State = State.STATE_DISCONNECTED,

wsadata: win.ws2_32.WSADATA = undefined,
socket: win.ws2_32.SOCKET = win.ws2_32.INVALID_SOCKET,
overlapped: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED),
event: win.HANDLE,

pub fn init(address: std.net.Address) anyerror!Self {
    const event = ws2_32.WSACreateEvent();
    if (0 == @intFromPtr(event)) {
        return @errorFromInt(@intFromEnum(ws2_32.WSAGetLastError()));
    }
    return Self{ .address = address, .event = event };
}

pub fn connect(self: *Self) !void {
    if (State.STATE_DISCONNECTED != self.state) {
        return WinSocketError.InvalidState;
    }

    self.wsadata = try win.WSAStartup(2, 2);

    self.socket = ws2_32.WSASocketW(ws2_32.AF.INET, ws2_32.SOCK.STREAM, ws2_32.IPPROTO.TCP, null, 0, ws2_32.WSA_FLAG_OVERLAPPED);
    if (ws2_32.INVALID_SOCKET == self.socket) {
        return WinSocketError.SocketCreationFailed;
    }

    const sockaddr = ws2_32.sockaddr.in{ .port = ws2_32.htons(self.address.getPort()), .addr = self.address.in.sa.addr };

    const ret = ws2_32.connect(self.socket, @ptrCast(&sockaddr), @sizeOf(@TypeOf(sockaddr)));
    if (ws2_32.SOCKET_ERROR == ret) {
        return WinSocketError.ConnectFailed;
    }

    self.state = State.STATE_CONNECTED;
}

pub fn disconnect(self: *Self) !void {
    if (State.STATE_CONNECTED != self.state) {
        return WinSocketError.InvalidState;
    }

    self.stream.close();
}

pub fn recv(self: *Self, buf: []u8, timeout: ?u32) !usize {
    if (State.STATE_DISCONNECTED == self.state) {
        return WinSocketError.InvalidState;
    }

    var ret: i32 = 0;
    var bytes_transferred: u32 = 0;
    var flags: u32 = 0;
    const wsabuf: ws2_32.WSABUF = .{ .len = @as(u31, @truncate(buf.len)), .buf = @constCast(@ptrCast(buf)) };

    @memset(std.mem.asBytes(&self.overlapped), 0x00);
    if (0 == ws2_32.WSAResetEvent(self.event)) {
        return @errorFromInt(@intFromEnum(ws2_32.WSAGetLastError()));
    }
    self.overlapped.hEvent = self.event;

    var wsabufs: [1]ws2_32.WSABUF = .{wsabuf};
    ret = ws2_32.WSARecv(self.socket, &wsabufs, wsabufs.len, null, &flags, &self.overlapped, null);
    if (ws2_32.SOCKET_ERROR == ret and ws2_32.WinsockError.WSA_IO_PENDING != ws2_32.WSAGetLastError()) {
        return WinSocketError.RecvFailed;
    }

    const wait: u32 = if (timeout) |t| (t) else win.INFINITE;

    try win.WaitForSingleObject(self.event, wait);

    ret = ws2_32.WSAGetOverlappedResult(self.socket, &self.overlapped, &bytes_transferred, 1, &flags);
    if (0 == ret) {
        return @errorFromInt(@intFromEnum(ws2_32.WSAGetLastError()));
    }

    return bytes_transferred;
}

pub fn recvAll(self: *Self, buf: []u8, timeout: ?u32) !usize {
    return self.recvAtLeast(buf, buf.len, timeout);
}

pub fn recvAtLeast(self: *Self, buf: []u8, len: usize, timeout: ?u32) !usize {
    var index: usize = 0;
    while (index < len) {
        const amt = try self.recv(buf[index..], timeout);
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

pub fn recvOne(self: *Self, timeout: ?u32) !u8 {
    var char: [1]u8 = .{0};

    _ = try self.recv(&char, timeout);

    std.debug.print("WinSocket.recvOne returning: {any}\n", .{char[0]});

    return char[0];
}

pub fn send(self: *Self, buf: []const u8) !usize {
    if (State.STATE_DISCONNECTED == self.state) {
        return WinSocketError.InvalidState;
    }

    var ret: i32 = 0;
    var bytes_transferred: u32 = 0;
    const flags: u32 = 0;
    const wsabuf: ws2_32.WSABUF = .{ .len = @as(u31, @truncate(buf.len)), .buf = @constCast(@ptrCast(buf)) };

    var wsabufs: [1]ws2_32.WSABUF = .{wsabuf};
    ret = ws2_32.WSASend(self.socket, &wsabufs, wsabufs.len, &bytes_transferred, flags, null, null);
    if (ws2_32.SOCKET_ERROR == ret and ws2_32.WinsockError.WSA_IO_PENDING != ws2_32.WSAGetLastError()) {
        return WinSocketError.SendFailed;
    }

    return bytes_transferred;
}

pub fn writeAll(self: Self, buf: []const u8) !void {
    var mutable_self = @constCast(&self);
    var index: usize = 0;
    while (index < buf.len) {
        const amt = try mutable_self.send(buf[index..]);
        index += amt;
    }
}

pub fn write(self: Self, buf: []const u8) !void {
    return self.writeAll(buf);
}

pub fn writeBytesNTimes(self: Self, buf: []const u8, n: usize) !void {
    for (0..n) |_| {
        try self.writeAll(buf);
    }
}

pub fn deinit(self: *Self) void {
    if (ws2_32.INVALID_SOCKET != self.socket) {
        _ = ws2_32.closesocket(self.socket);
    }
    self.state = State.STATE_DISCONNECTED;
    _ = ws2_32.WSACleanup();
}

// Unit tests

const ThreadArgs = struct {
    address: std.net.Address,
    semaphore: std.Thread.Semaphore,
    server: ?std.net.Server = null,
    connection: ?std.net.Server.Connection = null,
    test_data: []const u8 = "",
    test_data_len: usize = 0,
    out_data: []u8 = undefined,
};

fn test_start_server(args: *ThreadArgs) !void {
    var server = try args.address.listen(.{});

    args.semaphore.post();
    const connection = try server.accept();

    args.server = server;
    args.connection = connection;
}

fn test_send_data(args: *ThreadArgs) !void {
    args.semaphore.post();
    if (args.connection) |connection| {
        _ = try connection.stream.write(args.test_data);
    }
}

fn test_send_data_failure(args: *ThreadArgs) !void {
    args.semaphore.post();
}

fn test_recv_data(args: *ThreadArgs) !void {
    args.semaphore.post();
    if (args.connection) |connection| {
        _ = try connection.stream.read(args.out_data);
    }
}

fn test_recv_fmt_data(args: *ThreadArgs) !void {
    args.semaphore.post();
    if (args.connection) |connection| {
        var index: usize = 0;
        var amt = try connection.stream.read(args.out_data[index..]);
        index += amt;
        while (amt != 0) {
            amt = try connection.stream.read(args.out_data[index..]);
            index += amt;
        }
        args.test_data_len = index;
    }
}

fn test_recvAll_send_data(args: *ThreadArgs) !void {
    args.semaphore.post();
    if (args.connection) |connection| {
        for (args.test_data) |c| {
            const buf: [1]u8 = .{c};
            _ = try connection.stream.write(&buf);
            // sleep for 100 milliseconds
            std.time.sleep(1 * 1000 * 100);
        }
    }
}

test "connect unconnected socket" {
    const address = try std.net.Address.parseIp4("127.0.0.4", 4444);
    var s = try init(address);

    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
    };
    const thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();

    thread.join();

    try std.testing.expect(s.state == State.STATE_CONNECTED);

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}

test "recv data infinite timeout" {
    const address = try std.net.Address.parseIp4("127.0.0.5", 4445);
    var s = try init(address);

    const expected = "RecvDataInfiniteTimeout";
    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
        .test_data = expected,
    };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_send_data, .{&args});
    args.semaphore.wait();
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const received = try s.recv(&buf, null);

    try std.testing.expect(received == expected.len);
    try std.testing.expect(std.mem.eql(u8, buf[0..received], expected));

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}

test "recv data 5s timeout" {
    const address = try std.net.Address.parseIp4("127.0.0.6", 4446);
    var s = try init(address);

    const expected = "RecvData5secondTimeout";
    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
        .test_data = expected,
    };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_send_data, .{&args});
    args.semaphore.wait();
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const received = try s.recv(&buf, 5000);

    try std.testing.expect(received == expected.len);
    try std.testing.expect(std.mem.eql(u8, buf[0..received], expected));

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}

test "recv data timeout failure" {
    const address = try std.net.Address.parseIp4("127.0.0.7", 4447);
    var s = try init(address);

    const expected = "RecvData5secondTimeout";
    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
        .test_data = expected,
    };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_send_data_failure, .{&args});
    args.semaphore.wait();
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const received = s.recv(&buf, 1) catch |err| blk: {
        try std.testing.expect(err == win.WaitForSingleObjectError.WaitTimeOut);
        break :blk 0;
    };

    try std.testing.expect(0 == received);

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}

test "send data" {
    const address = try std.net.Address.parseIp4("127.0.0.8", 4448);
    var s = try init(address);

    const expected = "SendDataTest";
    var buf: [1024]u8 = [_]u8{0} ** 1024;
    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
        .out_data = &buf,
    };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_recv_data, .{&args});
    args.semaphore.wait();
    const sent = try s.send(@constCast(@ptrCast(expected)));

    try std.testing.expect(sent == expected.len);
    try std.testing.expect(std.mem.eql(u8, buf[0..sent], expected));

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}

test "recv partial data failure" {
    const address = try std.net.Address.parseIp4("127.0.0.9", 4449);
    var s = try init(address);

    const expected = "RecvPartialDataFilure";
    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
        .test_data = expected,
    };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_recvAll_send_data, .{&args});
    args.semaphore.wait();
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const received = try s.recv(&buf, null);
    thread.join();

    try std.testing.expect(received > 0);
    try std.testing.expect(received < expected.len);

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}

test "recvAll data" {
    const address = try std.net.Address.parseIp4("127.0.0.10", 4450);
    var s = try init(address);

    const expected = "RecvPartialDataFilure";
    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
        .test_data = expected,
    };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_recvAll_send_data, .{&args});
    args.semaphore.wait();
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const received = try s.recvAll(buf[0..expected.len], null);
    thread.join();

    try std.testing.expect(received == expected.len);
    try std.testing.expect(std.mem.eql(u8, buf[0..received], expected));

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}

test "writer fmt" {
    const address = try std.net.Address.parseIp4("127.0.0.11", 4451);
    var s = try init(address);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const format_string = "WriterFmtTest: {d} {s}";
    const format_args = .{ 0x1000, "TestFormatString" };
    var array = std.ArrayList(u8).init(allocator);
    defer array.deinit();

    try std.fmt.format(array.writer(), format_string, format_args);
    const expected = array.items;
    var buf: [1024]u8 = [_]u8{0} ** 1024;
    var args: ThreadArgs = .{
        .address = address,
        .semaphore = std.Thread.Semaphore{},
        .out_data = &buf,
    };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{&args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_recv_fmt_data, .{&args});
    args.semaphore.wait();
    try std.fmt.format(s, format_string, format_args);
    s.deinit();

    thread.join();

    try std.testing.expectEqual(args.test_data_len, expected.len);
    try std.testing.expect(std.mem.eql(u8, buf[0..args.test_data_len], expected));

    if (args.connection) |*connection| connection.stream.close();
    if (args.server) |*server| server.deinit();
}
