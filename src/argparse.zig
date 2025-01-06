const std = @import("std");

pub const ParseError = error{
    ArgumentMissingName,
    ArgumentMissingValue,
    ArgumentNameCollision,
};

const ParamType = enum {
    flag,
    value,
};

const ParamValue = union(ParamType) {
    flag: bool,
    value: []u8,
};

const Param = struct {
    const Self = @This();

    val: ParamValue,

    name: ?[]const u8,
    longname: ?[]const u8,

    pub fn clone(self: *Self, allocator: std.mem.Allocator) !Self {
        var param: Param = .{
            .val = self.val,
            .name = null,
            .longname = null,
        };

        if (self.name) |name| {
            param.name = try allocator.dupe(u8, name);
        }
        if (self.longname) |longname| {
            param.longname = try allocator.dupe(u8, longname);
        }

        switch (self.val) {
            ParamType.value => |val| {
                param.val.value = try allocator.dupe(u8, val);
            },
            else => {},
        }

        return param;
    }

    pub fn flag(self: Self) bool {
        return self.val.flag;
    }

    pub fn value(self: Self) []const u8 {
        return self.val.value;
    }
};

pub const ArgumentNamespace = struct {
    const Self = @This();

    args: std.StringHashMap(Param),
    positionals: std.ArrayList(Param),
    entries: std.ArrayList(Param),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .args = std.StringHashMap(Param).init(allocator),
            .entries = std.ArrayList(Param).init(allocator),
            .positionals = std.ArrayList(Param).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn add(self: *Self, arg: *Param) !void {
        const entry = try arg.clone(self.allocator);
        if (entry.name == null and entry.longname == null) {
            try self.positionals.append(entry);
        } else {
            if (entry.name) |name| {
                try self.args.put(name, entry);
            }
            if (entry.longname) |longname| {
                try self.args.put(longname, entry);
            }
        }
        try self.entries.append(entry);
    }

    pub fn get(self: Self, name: []const u8) Param {
        return self.args.get(name).?;
    }

    pub fn getFallible(self: Self, name: []const u8) ?Param {
        return self.args.get(name);
    }

    pub fn contains(self: Self, name: []const u8) bool {
        return self.args.contains(name);
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            if (entry.name) |name| {
                self.allocator.free(name);
            }
            if (entry.longname) |longname| {
                self.allocator.free(longname);
            }

            switch (entry.val) {
                ParamType.value => |val| {
                    self.allocator.free(val);
                },
                else => {},
            }
        }

        self.positionals.deinit();
        self.entries.deinit();
        self.args.deinit();
    }
};

pub const ArgumentParser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    options: std.ArrayList(Param),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .options = std.ArrayList(Param).init(allocator),
        };
    }

    pub fn addBoolArgument(self: *Self, name: ?[]const u8, longname: ?[]const u8, default: bool) !void {
        if (null == name and null == longname) {
            return error.ArgumentMissingName;
        }

        var param: Param = .{
            .name = null,
            .longname = null,
            .val = .{
                .flag = default,
            },
        };

        if (name) |n| {
            param.name = try self.allocator.dupe(u8, n);
        }
        if (longname) |ln| {
            param.longname = try self.allocator.dupe(u8, ln);
        }

        try self.options.append(param);
    }

    pub fn addValueArgument(self: *Self, name: ?[]const u8, longname: ?[]const u8) !void {
        if (null == name and null == longname) {
            return error.ArgumentMissingName;
        }

        var param: Param = .{
            .name = null,
            .longname = null,
            .val = .{
                .value = undefined,
            },
        };

        if (name) |n| {
            param.name = try self.allocator.dupe(u8, n);
        }
        if (longname) |ln| {
            param.longname = try self.allocator.dupe(u8, ln);
        }

        try self.options.append(param);
    }

    fn findOption(self: *Self, name: []const u8) ?*Param {
        for (self.options.items) |*option| {
            if (option.name) |n| {
                if (std.mem.eql(u8, name, n)) {
                    return option;
                }
            }
            if (option.longname) |ln| {
                if (std.mem.eql(u8, name, ln)) {
                    return option;
                }
            }
        }

        return null;
    }

    fn trim_left(s: []const u8, char: u8) []const u8 {
        var index: usize = 0;
        if (index < s.len and char == s[index]) {
            index += 1;
        }
        if (index < s.len and char == s[index]) {
            index += 1;
        }
        return s[index..];
    }

    pub fn parseArgs(self: *Self, cmd_line: []const u8) !ArgumentNamespace {
        var namespace: ArgumentNamespace = ArgumentNamespace.init(self.allocator);
        var iterator = try std.process.ArgIteratorGeneral(.{ .comments = true }).init(self.allocator, cmd_line);
        defer iterator.deinit();

        while (iterator.next()) |arg| {
            const trimmed = trim_left(arg, '-');

            if (arg.len > 0 and arg[0] != '-') {
                // got a positional
                const duped = try self.allocator.dupe(u8, trimmed);
                defer self.allocator.free(duped);
                var param: Param = .{
                    .name = null,
                    .longname = null,
                    .val = .{ .value = duped },
                };
                try namespace.add(&param);
                continue;
            }

            // otherwise handle named params
            const option = self.findOption(trimmed);
            if (option) |o| {
                switch (o.*.val) {
                    ParamType.flag => {
                        var param = namespace.getFallible(trimmed);
                        if (param) |*p| {
                            p.*.val.flag = !p.*.val.flag;
                        } else {
                            o.*.val.flag = !o.*.val.flag;
                            try namespace.add(o);
                        }
                    },
                    ParamType.value => |*val| {
                        const value = iterator.next() orelse return error.ArgumentMissingValue;
                        var param = namespace.getFallible(trimmed);
                        if (param) |*p| {
                            self.allocator.free(p.*.val.value);
                            p.*.val.value = try self.allocator.dupe(u8, value);
                        } else {
                            val.* = try self.allocator.dupe(u8, value);
                            try namespace.add(o);
                        }
                    },
                }
            }
        }

        return namespace;
    }

    pub fn parseArgsIterator(self: *Self, iterator: anytype) !ArgumentNamespace {
        var namespace: ArgumentNamespace = ArgumentNamespace.init(self.allocator);

        while (iterator.next()) |arg| {
            const trimmed = trim_left(arg, '-');

            if (arg.len > 0 and arg[0] != '-') {
                // got a positional
                const duped = try self.allocator.dupe(u8, trimmed);
                defer self.allocator.free(duped);
                var param: Param = .{
                    .name = null,
                    .longname = null,
                    .val = .{ .value = duped },
                };
                try namespace.add(&param);
                continue;
            }

            // otherwise handle named params
            const option = self.findOption(trimmed);
            if (option) |o| {
                switch (o.*.val) {
                    ParamType.flag => {
                        var param = namespace.getFallible(trimmed);
                        if (param) |*p| {
                            p.*.val.flag = !p.*.val.flag;
                        } else {
                            o.*.val.flag = !o.*.val.flag;
                            try namespace.add(o);
                        }
                    },
                    ParamType.value => |*val| {
                        const value = iterator.next() orelse return error.ArgumentMissingValue;
                        var param = namespace.getFallible(trimmed);
                        if (param) |*p| {
                            self.allocator.free(p.*.val.value);
                            p.*.val.value = try self.allocator.dupe(u8, value);
                        } else {
                            val.* = try self.allocator.dupe(u8, value);
                            try namespace.add(o);
                        }
                    },
                }
            }
        }

        return namespace;
    }

    pub fn deinit(self: Self) void {
        for (self.options.items) |o| {
            if (o.name) |name| {
                self.allocator.free(name);
            }
            if (o.longname) |longname| {
                self.allocator.free(longname);
            }
            switch (o.val) {
                ParamType.value => |val| {
                    self.allocator.free(val);
                },
                else => {},
            }
        }

        self.options.deinit();
    }
};

fn createBoolParam(comptime name: []const u8, parsed: bool) Param {
    return .{
        .val = .{
            .flag = parsed,
        },
        .name = name,
        .longname = name,
    };
}

const Options = std.StaticStringMap(Param).initComptime(.{
    .{ "a", .{ .val = .{ .flag = true }, .name = "a", .longname = "ascii" } },
    .{ "h", .{ .val = .{ .flag = true }, .name = "h", .longname = "human-readable" } },
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
        const option = Options.get(arg);
        if (option) |o| {
            switch (o.val) {
                ParamValue.flag => |val| {
                    try params.append(.{
                        .name = try allocator.dupe(u8, arg),
                        .longname = try allocator.dupe(u8, arg),
                        .val = .{
                            .flag = val,
                        },
                    });
                },
                ParamValue.value => |_| {
                    // would have to get the next arg from iter here
                    try params.append(.{
                        .name = try allocator.dupe(u8, arg),
                        .longname = try allocator.dupe(u8, arg),
                        .val = .{
                            .value = try allocator.dupe(u8, arg),
                        },
                    });
                },
            }
        }
    }

    const param = createBoolParam("t", false);
    std.debug.print("param: {any}\n", .{param});

    for (params.items) |p| {
        if (p.name) |name| {
            allocator.free(name);
        }
        if (p.longname) |longname| {
            allocator.free(longname);
        }
        switch (p.val) {
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

    try parser.addBoolArgument("f", "force", false);
    try parser.addValueArgument("o", "outfile");

    std.debug.print("Options: {any}\n", .{parser.options});
}

test "ArgumentParser test argParse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var parser = ArgumentParser.init(allocator);
    defer parser.deinit();

    try parser.addBoolArgument("f", "force", false);
    try parser.addValueArgument("o", "outfile");

    var args = try parser.parseArgs("ls -f --outfile filename pos1 pos2");
    defer args.deinit();

    const param1 = args.get("f");
    std.debug.print("param1: {any}\n", .{param1});
    std.debug.print("param1.flag(): {}\n", .{param1.flag()});
    try std.testing.expectEqual(param1.flag(), true);
    try std.testing.expectEqual(args.get("force").flag(), true);

    const param2 = args.get("outfile");
    std.debug.print("param2: {any}\n", .{param2});
    std.debug.print("param2.value(): {s}\n", .{param2.value()});
    try std.testing.expectEqualStrings(param2.value(), "filename");
    try std.testing.expectEqualStrings(args.get("o").value(), "filename");

    for (args.positionals.items, 0..) |param, i| {
        std.debug.print("Positional #{d}: {s}\n", .{ i, param.value() });
    }
    try std.testing.expectEqual(args.positionals.items.len, 3);
    try std.testing.expectEqualStrings(args.positionals.items[0].value(), "ls");
    try std.testing.expectEqualStrings(args.positionals.items[1].value(), "pos1");
    try std.testing.expectEqualStrings(args.positionals.items[2].value(), "pos2");
}
