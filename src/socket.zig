const std = @import("std");
const win = std.os.windows;
const ws2_32 = win.ws2_32;

const SocketError = error{
    InvalidState,
    SocketCreationFailed,
    ConnectFailed,
    RecvFailed,
    RecvTimeout,
};

pub const Socket = struct {
    const Self = @This();

    const State = enum(u32) {
        STATE_DISCONNECTED = 0,
        STATE_CONNECTED,
    };

    allocator: std.mem.Allocator,
    address: std.net.Address,
    state: State = State.STATE_DISCONNECTED,

    wsadata: win.ws2_32.WSADATA = undefined,
    socket: win.ws2_32.SOCKET = win.ws2_32.INVALID_SOCKET,
    overlapped: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED),
    event: win.HANDLE,

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address) anyerror!Self {
        const event = ws2_32.WSACreateEvent();
        if (0 == @intFromPtr(event)) {
            return @errorFromInt(@intFromEnum(ws2_32.WSAGetLastError()));
        }
        return Self{ .allocator = allocator, .address = address, .event = event };
    }

    pub fn connect(self: *Self) !void {
        if (State.STATE_DISCONNECTED != self.state) {
            return SocketError.InvalidState;
        }

        self.wsadata = try win.WSAStartup(2, 2);

        self.socket = ws2_32.WSASocketW(ws2_32.AF.INET, ws2_32.SOCK.STREAM, ws2_32.IPPROTO.TCP, null, 0, ws2_32.WSA_FLAG_OVERLAPPED);
        if (ws2_32.INVALID_SOCKET == self.socket) {
            return SocketError.SocketCreationFailed;
        }

        const sockaddr = ws2_32.sockaddr.in{ .port = ws2_32.htons(self.address.getPort()), .addr = self.address.in.sa.addr };

        const ret = ws2_32.connect(self.socket, @ptrCast(&sockaddr), @sizeOf(@TypeOf(sockaddr)));
        if (ws2_32.SOCKET_ERROR == ret) {
            return SocketError.ConnectFailed;
        }

        self.state = State.STATE_CONNECTED;
    }

    pub fn disconnect(self: *Self) !void {
        if (State.STATE_CONNECTED != self.state) {
            return SocketError.InvalidState;
        }

        self.stream.close();
    }

    pub fn recv(self: *Self, buf: []u8, timeout: ?u32) !usize {
        if (State.STATE_DISCONNECTED == self.state) {
            return SocketError.InvalidState;
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
            return SocketError.RecvFailed;
        }

        const wait: u32 = if (timeout) |t| t * 1000 else win.INFINITE;

        try win.WaitForSingleObject(self.event, wait);

        ret = ws2_32.WSAGetOverlappedResult(self.socket, &self.overlapped, &bytes_transferred, 1, &flags);
        if (0 == ret) {
            return @errorFromInt(@intFromEnum(ws2_32.WSAGetLastError()));
        }

        return bytes_transferred;
    }

    pub fn deinit(self: *Self) !void {
        if (ws2_32.INVALID_SOCKET != self.socket) {
            ws2_32.closesocket(self.socket);
        }
        ws2_32.WSACleanup();
    }
};

// Unit tests

const ThreadArgs = struct {
    address: std.net.Address,
    semaphore: std.Thread.Semaphore,
    server: ?*std.net.Server = null,
    connection: ?*std.net.Server.Connection = null,
};

fn test_start_server(args: ThreadArgs) !void {
    var server = try args.address.listen(.{});

    args.semaphore.post();
    const connection = try server.accept();

    args.server = server;
    args.connection = connection;
}

fn test_send_data(args: ThreadArgs) !void {
    args.semaphore.post();
    if (args.connection) |connection| {
        connection.stream.write("HelloFromTest");
    }
}

test "connect unconnected socket" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const address = try std.net.Address.parseIp4("127.0.0.1", 4444);
    var s = try Socket.init(allocator, address);

    const args: ThreadArgs = .{ .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 4444), .semaphore = std.Thread.Semaphore{} };
    const thread = try std.Thread.spawn(.{}, test_start_server, .{args});

    args.semaphore.wait();
    try s.connect();

    thread.join();

    try std.testing.expect(s.state == Socket.State.STATE_CONNECTED);

    if (args.connection) |connection| connection.close();
    if (args.server) |server| server.deinit();
}

test "recv data infinite timeout" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const address = try std.net.Address.parseIp4("127.0.0.1", 4444);
    var s = try Socket.init(allocator, address);

    const args: ThreadArgs = .{ .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 4444), .semaphore = std.Thread.Semaphore{} };
    var thread = try std.Thread.spawn(.{}, test_start_server, .{args});

    args.semaphore.wait();
    try s.connect();
    thread.join();

    thread = try std.Thread.spawn(.{}, test_send_data, .{args});
    args.semaphore.wait();
    const buf: [4096]u8 = [_]u8{0} ** 4096;
    try s.recv(buf, null);

    if (args.connection) |connection| connection.close();
    if (args.server) |server| server.deinit();
}
