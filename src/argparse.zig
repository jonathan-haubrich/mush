const std = @import("std");

pub const ParseError = error{
    ArgumentMissingName,
    ArgumentMissingValue,
    ArgumentNameCollision,
    ArgumentPositionalOutOfRange,
};

const ParamType = enum {
    flag,
    named,
    positional,
};

const ParamValueType = enum {
    flag,
    value,
};

const ParamValue = union(ParamValueType) {
    flag: bool,
    value: ?[]u8,
};

const Param = struct {
    const Self = @This();

    val: ParamValue,
    typ: ParamType,

    name: ?[]const u8,
    longname: ?[]const u8,
    required: bool,

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        var param: Param = .{
            .val = self.val,
            .typ = self.typ,
            .required = self.required,
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
            ParamValueType.value => |val| {
                if (val) |v| {
                    param.val.value = try allocator.dupe(u8, v);
                }
            },
            else => {},
        }

        return param;
    }

    pub fn flag(self: Self) bool {
        return self.val.flag;
    }

    pub fn value(self: Self) []const u8 {
        return self.val.value.?;
    }
};

pub const ArgumentNamespace = struct {
    const Self = @This();

    args: std.StringHashMap(Param),
    positionals: std.ArrayList(Param),
    entries: std.ArrayList(Param),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, entries: std.ArrayList(Param)) !Self {
        var _entries = try std.ArrayList(Param).initCapacity(allocator, entries.capacity);
        var args_map = std.StringHashMap(Param).init(allocator);
        var positionals = std.ArrayList(Param).init(allocator);

        for (entries.items) |entry| {
            const cloned = try entry.clone(allocator);
            try _entries.append(cloned);

            if (entry.typ == .positional) {
                try positionals.append(cloned);
            } else {
                if (entry.name) |name| {
                    try args_map.put(name, cloned);
                }
                if (entry.longname) |longname| {
                    try args_map.put(longname, cloned);
                }
            }
        }

        return .{
            .args = args_map,
            .entries = _entries,
            .positionals = positionals,
            .allocator = allocator,
        };
    }

    pub fn get(self: Self, name: []const u8) Param {
        return self.args.get(name).?;
    }

    pub fn set_named_value(self: Self, name: []const u8, value: []const u8) !bool {
        var param = self.getFallible(name);
        if (param) |*p| {
            // if param was already set, make sure we don't leak
            if (p.val.value) |v| {
                self.allocator.free(v);
            }
            p.val.value = try self.allocator.dupe(u8, value);
            return true;
        }

        return false;
    }

    pub fn set_positional_value(self: *Self, value: []const u8) !bool {
        for (self.positionals.items) |*positional| {
            if (positional.val.value) |_| {
                continue;
            } else {
                positional.val.value = try self.allocator.dupe(u8, value);
                return true;
            }
        }

        // no positionals or unassigned positionals found
        return error.ArgumentPositionalOutOfRange;
    }

    pub fn set_flag(self: Self, name: []const u8) bool {
        var param = self.getFallible(name);
        if (param) |*p| {
            p.val.flag = !p.val.flag;
            return true;
        }

        return false;
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
                ParamValueType.value => |val| {
                    if (val) |v| {
                        self.allocator.free(v);
                    }
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
            .required = true,
            .val = .{
                .flag = default,
            },
            .typ = .flag,
        };

        if (name) |n| {
            param.name = try self.allocator.dupe(u8, n);
        }
        if (longname) |ln| {
            param.longname = try self.allocator.dupe(u8, ln);
        }

        try self.options.append(param);
    }

    fn addArgument(self: *Self, name: ?[]const u8, longname: ?[]const u8, required: bool, typ: ParamType) !void {
        var param: Param = .{
            .name = null,
            .longname = null,
            .required = required,
            .val = .{
                .value = null,
            },
            .typ = typ,
        };

        if (name) |n| {
            param.name = try self.allocator.dupe(u8, n);
        }
        if (longname) |ln| {
            param.longname = try self.allocator.dupe(u8, ln);
        }

        try self.options.append(param);
    }

    pub fn addValueArgument(self: *Self, name: ?[]const u8, longname: ?[]const u8, required: bool) !void {
        if (null == name and null == longname) {
            return error.ArgumentMissingName;
        }

        return self.addArgument(name, longname, required, .named);
    }

    pub fn addPositionalArgument(self: *Self, name: ?[]const u8, longname: ?[]const u8, required: bool) !void {
        if (null == name and null == longname) {
            return error.ArgumentMissingName;
        }

        return self.addArgument(name, longname, required, .positional);
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
        var iterator = try std.process.ArgIteratorGeneral(.{ .comments = true }).init(self.allocator, cmd_line);
        defer iterator.deinit();

        return self.parseArgsIterator(iterator);
    }

    pub fn parseArgsIterator(self: *Self, iterator: anytype) !ArgumentNamespace {
        var namespace: ArgumentNamespace = try ArgumentNamespace.init(self.allocator, self.options);

        while (iterator.next()) |arg| {
            if (arg.len > 0 and arg[0] != '-') {
                // got a positional
                _ = try namespace.set_positional_value(arg);
                continue;
            }

            // otherwise handle named params
            const trimmed = trim_left(arg, '-');
            const param = namespace.getFallible(trimmed);
            if (param) |*p| {
                switch (p.*.val) {
                    ParamValueType.flag => {
                        _ = namespace.set_flag(trimmed);
                    },
                    ParamValueType.value => {
                        const value = iterator.next() orelse return error.ArgumentMissingValue;
                        _ = try namespace.set_named_value(trimmed, value);
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
                ParamValueType.value => |val| {
                    if (val) |v| {
                        self.allocator.free(v);
                    }
                },
                else => {},
            }
        }

        self.options.deinit();
    }
};

test "ArgumentParser add options" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var parser = ArgumentParser.init(allocator);
    defer parser.deinit();

    try parser.addBoolArgument("f", "force", false);
    try parser.addValueArgument("o", "outfile", true);

    std.debug.print("Options: {any}\n", .{parser.options});
}

test "ArgumentParser test argParse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var parser = ArgumentParser.init(allocator);
    defer parser.deinit();

    try parser.addBoolArgument("f", "force", false);
    try parser.addValueArgument("o", "outfile", true);

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
