const std = @import("std");
const socket = @import("winsocket.zig");

pub fn main() !void {
    var ha = std.heap.HeapAllocator.init();
    const allocator = ha.allocator();

    const address = try std.net.Address.parseIp("172.20.42.248", 4444);

    var s = try socket.Socket.init(allocator, address);

    try s.connect();

    var buf: [4096]u8 = [_]u8{0} ** 4096;

    const ret = s.recv(&buf, 10) catch |err| def: {
        std.debug.print("Socket.recv failed: {}", .{err});

        break :def 0;
    };

    std.debug.print("Received {d} bytes: {s}", .{ ret, buf });
}
