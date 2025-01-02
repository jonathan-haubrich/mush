const std = @import("std");
const win = std.os.windows;

fn format_walker_entry(entry: std.fs.Dir.Walker.Entry, writer: anytype) !void {
    const kind = switch (entry.kind) {
        .file => "<FILE>",
        .directory => "<DIR>",
        .sym_link => "<SYMLINK>",
        else => "<UNKNOWN>",
    };

    try std.fmt.format(writer, "{s} {s}", .{ kind, entry.path });
}

fn format_dir_entry(entry: anytype, writer: anytype) !void {
    const kind = switch (entry.kind) {
        .file => "<FILE>",
        .directory => "<DIR>",
        .sym_link => "<SYMLINK>",
        else => "<UNKNOWN>",
    };

    try std.fmt.format(writer, "{s} {s}", .{ kind, entry.name });
}

pub fn ls(path: []const u8, recusrive: bool, writer: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const abspath = try std.fs.realpathAlloc(allocator, path);
    defer allocator.free(abspath);

    var dir_handle = try std.fs.openDirAbsolute(abspath, .{ .iterate = true });
    defer dir_handle.close();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    if (recusrive) {
        var walker = try dir_handle.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            buffer.clearRetainingCapacity();
            try format_walker_entry(entry, buffer.writer());

            try buffer.appendSlice("\r\n");
            try writer.write(buffer.items);
        }
    } else {
        var iterator = dir_handle.iterate();
        while (try iterator.next()) |entry| {
            buffer.clearRetainingCapacity();
            try format_dir_entry(entry, buffer.writer());

            try buffer.appendSlice("\r\n");
            try writer.write(buffer.items);
        }
    }
}
