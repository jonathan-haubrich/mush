const std = @import("std");
const win = std.os.windows;
const argparse = @import("argparse");
const CommandArgIterator = @import("commands.zig").CommandArgIterator;

const CommandError = error{
    InvalidArgument,
};

const FMT_SHORT_LISTING = "{[kind]s}  {[size]s}  {[name]s}";
const FMT_LONG_LISTING = "{[kind]s} {[inode]d} {[size]s}  {[name]s}";

fn parse_options(args_iter: *CommandArgIterator, allocator: std.mem.Allocator) !argparse.ArgumentNamespace {
    var parser = argparse.ArgumentParser.init(allocator);
    defer parser.deinit();
    try parser.addBoolArgument("h", "human-readable", false);
    try parser.addBoolArgument("r", "recursive", false);
    try parser.addBoolArgument("l", "long-listing", false);
    try parser.addBoolArgument("a", "absolute-paths", false);

    const args = try parser.parseArgsIterator(args_iter);

    return args;
}

fn format_walker_entry(entry: std.fs.Dir.Walker.Entry, options: argparse.ArgumentNamespace, writer: anytype) !void {
    const kind = switch (entry.kind) {
        .file => "<FILE>",
        .directory => "<DIR>",
        .sym_link => "<SYMLINK>",
        else => "<UNKNOWN>",
    };

    const stat = try entry.dir.stat();

    var size_buffer: [32]u8 = [_]u8{0} ** 32;

    if (options.contains("h") and options.get("h").flag()) {
        _ = try std.fmt.bufPrint(&size_buffer, "{}", .{std.fmt.fmtIntSizeDec(stat.size)});
    } else {
        _ = try std.fmt.bufPrint(&size_buffer, "{d}", .{stat.size});
    }

    if (options.contains("l") and options.get("l").flag()) {
        try std.fmt.format(writer, FMT_LONG_LISTING, .{ .kind = kind, .inode = stat.inode, .size = size_buffer, .name = entry.path });
    } else {
        try std.fmt.format(writer, FMT_SHORT_LISTING, .{ .kind = kind, .size = size_buffer, .name = entry.path });
    }
}

fn format_dir_entry(dir: std.fs.Dir, entry: anytype, options: argparse.ArgumentNamespace, writer: anytype) !void {
    const kind = switch (entry.kind) {
        .file => "<FILE>",
        .directory => "<DIR>",
        .sym_link => "<SYMLINK>",
        else => "<UNKNOWN>",
    };

    const stat = dir.statFile(entry.name) catch |err| switch (err) {
        std.fs.File.OpenError.IsDir => try dir.stat(),
        else => return err,
    };

    var size_buffer: [32]u8 = [_]u8{0} ** 32;

    if (options.contains("h") and options.get("h").flag()) {
        _ = try std.fmt.bufPrint(&size_buffer, "{}", .{std.fmt.fmtIntSizeDec(stat.size)});
    } else {
        _ = try std.fmt.bufPrint(&size_buffer, "{d}", .{stat.size});
    }

    if (options.contains("l") and options.get("l").flag()) {
        try std.fmt.format(writer, FMT_LONG_LISTING, .{ .kind = kind, .inode = stat.inode, .size = size_buffer, .name = entry.name });
    } else {
        try std.fmt.format(writer, FMT_SHORT_LISTING, .{ .kind = kind, .size = size_buffer, .name = entry.name });
    }
}

pub fn ls(args_iter: *CommandArgIterator, writer: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var options = parse_options(args_iter, allocator) catch |err| {
        try std.fmt.format(writer, "[ERROR] Parsing options failed: {}\r\n", .{err});
        return;
    };
    defer options.deinit();

    std.debug.print("Got positionals: {any}\n", .{options.positionals});

    for (options.positionals.items) |param| {
        const path = param.value();
        std.debug.print("Got path: {s}\n", .{path});
        const abspath = try std.fs.realpathAlloc(allocator, path);
        defer allocator.free(abspath);

        var dir_handle = try std.fs.openDirAbsolute(abspath, .{ .iterate = true });
        defer dir_handle.close();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        if (options.contains("r") and options.get("r").flag()) {
            var walker = try dir_handle.walk(allocator);
            defer walker.deinit();

            while (true) {
                buffer.clearRetainingCapacity();

                const entry = walker.next() catch |err| {
                    try std.fmt.format(writer, "[ERROR]: {}\r\n", .{err});
                    continue;
                };

                if (entry) |e| {
                    format_walker_entry(e, options, buffer.writer()) catch |err| {
                        try std.fmt.format(writer, "[ERROR] {s}: {}\r\n", .{ e.path, err });
                        continue;
                    };
                } else {
                    break;
                }

                try buffer.appendSlice("\r\n");
                try writer.write(buffer.items);
            }
        } else {
            var iterator = dir_handle.iterate();
            while (true) {
                buffer.clearRetainingCapacity();

                const entry = iterator.next() catch |err| {
                    try std.fmt.format(writer, "[ERROR]: {}\r\n", .{err});
                    continue;
                };

                if (entry) |e| {
                    format_dir_entry(dir_handle, e, options, buffer.writer()) catch |err| {
                        try std.fmt.format(writer, "[ERROR] {s}: {}\r\n", .{ e.name, err });
                        continue;
                    };
                } else {
                    break;
                }

                try buffer.appendSlice("\r\n");
                try writer.write(buffer.items);
            }
        }
    }
}
