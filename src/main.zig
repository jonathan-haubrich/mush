const std = @import("std");
const socket = @import("socket.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const address = try std.net.Address.parseIp4("172.20.42.248", 4444);
    var sock = socket.Socket.init(allocator, address);

    try sock.connect();
}
