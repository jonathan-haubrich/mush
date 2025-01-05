const std = @import("std");

const ParamType = enum {
    flag,
    value,
};

const ParamValue = union(ParamType) {
    flag: bool,
    value: []u8,
};

const Param = struct {
    value: ParamValue,

    name: []const u8,
    longname: []const u8,
};

const ArgumentParser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    options: std.ArrayList(Param),
    positionals: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .options = std.ArrayList(Param).init(allocator),
            .positionals = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn add_bool_argument(self: *Self, name: []const u8, longname: []const u8, default: bool) !void {
        try self.options.append(.{
            .name = try self.allocator.dupe(u8, name),
            .longname = try self.allocator.dupe(u8, longname),
            .value = .{
                .flag = default,
            },
        });
    }

    pub fn add_value_argument(self: *Self, name: []const u8, longname: []const u8) !void {
        try self.options.append(.{
            .name = try self.allocator.dupe(u8, name),
            .longname = try self.allocator.dupe(u8, longname),
            .value = .{
                .value = "",
            },
        });
    }

    pub fn deinit(self: Self) void {
        for (self.options.items) |o| {
            self.allocator.free(o.name);
            self.allocator.free(o.longname);
            switch (o.value) {
                ParamValue.value => |val| {
                    self.allocator.free(val);
                },
                else => {},
            }
        }

        self.options.deinit();
    }
};

fn create_bool_param(comptime name: []const u8, parsed: bool) Param {
    return .{
        .value = .{
            .flag = parsed,
        },
        .name = name,
        .longname = name,
    };
}

const Options = std.StaticStringMap(Param).initComptime(.{
    .{ "-a", .{ .value = .{ .flag = true }, .name = "-a", .longname = "--ascii" } },
    .{ "-h", .{ .value = .{ .flag = true }, .name = "-h", .longname = "--human-readable" } },
});

test "ArgParse test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var params = std.ArrayList(Param).init(allocator);
    defer params.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(allocator, "ls -a -h");
    defer iter.deinit();
    while (iter.next()) |arg| {
        std.debug.print("arg: {s}\n", .{arg});

        const option = Options.get(arg);
        if (option) |o| {
            switch (o.value) {
                ParamValue.flag => |val| {
                    try params.append(.{
                        .name = try allocator.dupe(u8, arg),
                        .longname = try allocator.dupe(u8, arg),
                        .value = .{
                            .flag = val,
                        },
                    });
                },
                ParamValue.value => |_| {
                    // would have to get the next arg from iter here
                    try params.append(.{
                        .name = try allocator.dupe(u8, arg),
                        .longname = try allocator.dupe(u8, arg),
                        .value = .{
                            .value = try allocator.dupe(u8, arg),
                        },
                    });
                },
            }
        }
    }

    const param = create_bool_param("-t", false);
    std.debug.print("param: {any}\n", .{param});

    for (params.items) |p| {
        allocator.free(p.name);
        allocator.free(p.longname);
        switch (p.value) {
            ParamValue.value => |val| {
                allocator.free(val);
            },
            else => {},
        }
    }
}

test "ArgumentParser add options" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var parser = ArgumentParser.init(allocator);
    defer parser.deinit();

    try parser.add_bool_argument("-f", "--force", false);
    try parser.add_value_argument("-o", "--outfile");

    std.debug.print("Options: {any}\n", .{parser.options});
}
