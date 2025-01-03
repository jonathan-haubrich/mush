const std = @import("std");
const win = std.os.windows;

const commands = @import("commands.zig");

const CommandError = error{
    InvalidArgument,
};

const LsOptions = struct {
    path: [:0]const u8 = "",

    recursive: bool = false,
    absolute_paths: bool = false,
    long_listing: bool = false,
    human_friendly: bool = false,
};

const SupportedOptions = std.StaticStringMap([]const u8).initComptime(.{
    .{ "-r", "recursive" },
    .{ "-a", "absolute_paths" },
    .{ "-h", "human_friendly" },
    .{ "-l", "long_listing" },
});

const FMT_SHORT_LISTING = "{[kind]s}  {[size]s}  {[name]s}";
const FMT_LONG_LISTING = "{[kind]s} {[inode]d} {[size]s}  {[name]s}";

fn parse_options(args_iter: *commands.CommandargIterator, allocator: std.mem.Allocator) !LsOptions {
    var options: LsOptions = .{};
    var positionals: u32 = 0;

    var path: ?[:0]const u8 = null;

    while (args_iter.next()) |arg| {
        std.debug.print("Handling arg: {s}\n", .{arg});
        if (std.mem.eql(u8, arg, "-r")) {
            options.recursive = true;
        } else if (std.mem.eql(u8, arg, "-a")) {
            options.absolute_paths = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            options.human_friendly = true;
        } else if (std.mem.eql(u8, arg, "-l")) {
            options.long_listing = true;
        } else {
            positionals += 1;
            if (positionals > 1) {
                if (path) |p| {
                    allocator.free(p);
                }
                return CommandError.InvalidArgument;
            }

            path = try allocator.dupeZ(u8, arg);
        }
    }

    options.path = path.?;

    return options;
}

fn format_walker_entry(entry: std.fs.Dir.Walker.Entry, options: LsOptions, writer: anytype) !void {
    const kind = switch (entry.kind) {
        .file => "<FILE>",
        .directory => "<DIR>",
        .sym_link => "<SYMLINK>",
        else => "<UNKNOWN>",
    };

    const stat = try entry.dir.stat();

    var size_buffer: [32]u8 = [_]u8{0} ** 32;

    if (options.human_friendly) {
        _ = try std.fmt.bufPrint(&size_buffer, "{}", .{std.fmt.fmtIntSizeDec(stat.size)});
    } else {
        _ = try std.fmt.bufPrint(&size_buffer, "{d}", .{stat.size});
    }

    if (options.long_listing) {
        try std.fmt.format(writer, FMT_LONG_LISTING, .{ .kind = kind, .inode = stat.inode, .size = size_buffer, .name = entry.path });
    } else {
        try std.fmt.format(writer, FMT_SHORT_LISTING, .{ .kind = kind, .size = size_buffer, .name = entry.path });
    }
}

fn format_dir_entry(dir: std.fs.Dir, entry: anytype, options: LsOptions, writer: anytype) !void {
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

    if (options.human_friendly) {
        _ = try std.fmt.bufPrint(&size_buffer, "{}", .{std.fmt.fmtIntSizeDec(stat.size)});
    } else {
        _ = try std.fmt.bufPrint(&size_buffer, "{d}", .{stat.size});
    }

    if (options.long_listing) {
        try std.fmt.format(writer, FMT_LONG_LISTING, .{ .kind = kind, .inode = stat.inode, .size = size_buffer, .name = entry.name });
    } else {
        try std.fmt.format(writer, FMT_SHORT_LISTING, .{ .kind = kind, .size = size_buffer, .name = entry.name });
    }
}

pub fn ls(args_iter: *commands.CommandargIterator, writer: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const options = parse_options(args_iter, allocator) catch |err| {
        try std.fmt.format(writer, "[ERROR] Parsing options failed: {}\r\n", .{err});
        return;
    };
    defer allocator.free(options.path);

    const abspath = try std.fs.realpathAlloc(allocator, options.path);
    defer allocator.free(abspath);

    var dir_handle = try std.fs.openDirAbsolute(abspath, .{ .iterate = true });
    defer dir_handle.close();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    if (options.recursive) {
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
