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

    pub fn recv(self: *Self, buf: []const u8, timeout: ?u32) !usize {
        if (State.STATE_DISCONNECTED == self.state) {
            return SocketError.InvalidState;
        }

        const ret = 0;
        const bytes_transferred = 0;
        const flags = 0;
        const wsabuf = ws2_32.WSABUF{};
        wsabuf.buf = &buf;
        wsabuf.len = buf.len;

        @memset(&self.overlapped, 0x00);
        if (false == ws2_32.WSAResetEvent(self.event)) {
            return ws2_32.WSAGetLastError();
        }
        self.overlapped.hEvent = self.event;

        ret = ws2_32.WSARecv(self.socket, &wsabuf, 1, null, &flags, &self.overlapped, null);
        if (ws2_32.SOCKET_ERROR == ret and ws2_32.WinsockError.WSA_IO_PENDING != ws2_32.WSAGetLastError()) {
            return SocketError.RecvFailed;
        }

        timeout = (timeout * 1000) orelse win.INFINITE;
        ret = win.WaitForSingleObject(self.event, timeout);
        if (win.WAIT_TIMEOUT == ret) {
            return SocketError.RecvTimeout;
        } else if (win.WAIT_FAILED == ret) {
            return win.GetLastError();
        }

        ret = ws2_32.WSAGetOverlappedResult(self.socket, &self.overlapped, &bytes_transferred, true, &flags);
        if (false == ret) {
            return ws2_32.WSAGetLastError();
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

const ThreadArgs = struct {
    address: std.net.Address,
};

fn test_start_server(args: ThreadArgs) !void {
    var server = try args.address.listen(.{});
    const connection = try server.accept();

    connection.stream.close();
}

test "connect unconnected socket" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const address = try std.net.Address.parseIp4("127.0.0.1", 4444);
    var s = try Socket.init(allocator, address);

    const args: ThreadArgs = .{ .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 4444) };
    const thread = try std.Thread.spawn(.{}, test_start_server, .{args});

    std.time.sleep(1 * 1000 * 1000);

    try s.connect();

    thread.join();

    try std.testing.expect(s.state == Socket.State.STATE_CONNECTED);
}
