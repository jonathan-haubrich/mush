const std = @import("std");

const SocketError = error{
    InvalidState,
};

pub const Socket = struct {
    const Self = @This();

    const State = enum(u32) {
        STATE_DISCONNECTED = 0,
        STATE_CONNECTED,
    };

    allocator: std.mem.Allocator,
    address: std.net.Address,
    stream: std.net.Stream = undefined,
    state: State = State.STATE_DISCONNECTED,

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address) Self {
        return Self{ .allocator = allocator, .address = address };
    }

    pub fn connect(self: *Self) !void {
        if (State.STATE_DISCONNECTED != self.state) {
            return SocketError.InvalidState;
        }

        self.stream = try std.net.tcpConnectToAddress(self.address);

        self.state = State.STATE_CONNECTED;
    }

    pub fn disconnect(self: *Self) !void {
        if (State.STATE_CONNECTED != self.state) {
            return SocketError.InvalidState;
        }

        self.stream.close();
    }

    pub fn recv(self: *Self, buf: []const u8) !usize {
        if (State.STATE_DISCONNECTED == self.state) {
            return SocketError.InvalidState;
        }

        return self.stream.read(buf);
    }
};
