const std = @import("std");
const WinSocket = @import("winsocket.zig");
const RemoteTty = @import("remotetty.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const address = try std.net.Address.parseIp("172.20.42.248", 4444);
    var winsock = try WinSocket.init(address);
    defer winsock.deinit();

    try winsock.connect();

    var rtty = try RemoteTty.init(&winsock, allocator);
    defer rtty.deinit();

    const commandline = try rtty.get_command_line();
    std.debug.print("commandline: {s}\n", .{commandline});

    allocator.free(commandline);
}
