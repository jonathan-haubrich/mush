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

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        switch (self.val) {
            ParamValueType.value => |val| {
                if (val) |v| {
                    allocator.free(v);
                }
            },
            else => {},
        }

        if (self.name) |name| {
            allocator.free(name);
        }
        if (self.longname) |longname| {
            allocator.free(longname);
        }
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

    args: std.StringHashMap(*Param),
    entries: std.ArrayList(Param),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, entries: std.ArrayList(Param)) !Self {
        var _entries = try std.ArrayList(Param).initCapacity(allocator, entries.capacity);
        var args_map = std.StringHashMap(*Param).init(allocator);
        errdefer {
            for (_entries.items) |entry| {
                entry.deinit(allocator);
            }

            _entries.deinit();
            args_map.deinit();
        }

        for (entries.items) |entry| {
            const cloned = try entry.clone(allocator);
            try _entries.append(cloned);

            const entry_ptr = &_entries.items[_entries.items.len - 1];

            if (entry_ptr.name) |name| {
                try args_map.put(name, entry_ptr);
            }
            if (entry_ptr.longname) |longname| {
                try args_map.put(longname, entry_ptr);
            }
        }

        var key_iterator = args_map.keyIterator();
        std.debug.print("[ArgumentNamespace.init: args.ctx addr: {*}]===== Have keys:\n", .{&args_map.ctx});
        while (key_iterator.next()) |key| {
            std.debug.print("\t{s}\n", .{key.*});
        }
        std.debug.print("[ArgumentNamespace.init: args.unmanaged addr: {*}]===== Have keys:\n", .{&args_map.unmanaged});

        return .{
            .args = args_map,
            .entries = _entries,
            .allocator = allocator,
        };
    }

    pub fn get(self: Self, name: []const u8) Param {
        var key_iterator = self.args.keyIterator();
        std.debug.print("[ArgumentNamespace.get: self.args.ctx addr: {*}]===== Have keys:\n", .{&self.args.ctx});
        while (key_iterator.next()) |key| {
            std.debug.print("\t{s}\n", .{key.*});
        }
        std.debug.print("[ArgumentNamespace.init: args.unmanaged addr: {*}]===== Have keys:\n", .{&self.args.unmanaged});

        return self.args.get(name).?.*;
    }

    pub fn set_named_value(self: Self, name: []const u8, value: []const u8) !bool {
        const param = self.args.get(name);
        if (param) |p| {
            // if param was already set, make sure we don't leak
            if (p.*.val.value) |v| {
                self.allocator.free(v);
            }
            p.*.val.value = try self.allocator.dupe(u8, value);
            return true;
        }

        return false;
    }

    pub fn set_positional_value(self: *Self, value: []const u8) !bool {
        var first_available: ?*Param = null;

        for (self.entries.items) |*entry| {
            if (entry.typ == .positional) {
                if (entry.val.value) |_| {
                    continue;
                } else {
                    // want to set required positionals first
                    // if we find an available entry, check to see if it's required
                    // if not, keep going but save off entry for setting
                    // if we don't find an optional that isn't set
                    first_available = first_available orelse entry;
                    if (entry.required) {
                        entry.val.value = try self.allocator.dupe(u8, value);
                        return true;
                    }
                }
            }
        }

        // if we got here, we didn't find any required positionals that weren't set
        // or we didn't find anything. but if we found an optional that wasn't set
        // set it now and return true if possible
        if (first_available) |fa| {
            fa.val.value = try self.allocator.dupe(u8, value);
            return true;
        }

        // no positionals or unassigned positionals found
        return error.ArgumentPositionalOutOfRange;
    }

    pub fn set_flag(self: Self, name: []const u8) bool {
        const param = self.getFallible(name);
        if (param) |p| {
            p.val.flag = !p.val.flag;
            return true;
        }

        return false;
    }

    pub fn getFallible(self: Self, name: []const u8) ?*Param {
        return self.args.get(name);
    }

    pub fn contains(self: Self, name: []const u8) bool {
        return self.args.contains(name);
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }

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
            errdefer {
                self.allocator.free(param.name);
                param.name = null;
            }
        }
        if (longname) |ln| {
            param.longname = try self.allocator.dupe(u8, ln);
            errdefer {
                self.allocator.free(param.name);
                param.longname = null;
            }
        }

        try self.options.append(param);
    }

    fn addArgument(self: *Self, name: ?[]const u8, longname: ?[]const u8, required: bool, typ: ParamType) !void {
        if (null == name and null == longname) {
            return error.ArgumentMissingName;
        }

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
        return self.addArgument(name, longname, required, .named);
    }

    pub fn addPositionalArgument(self: *Self, name: ?[]const u8, longname: ?[]const u8, required: bool) !void {
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

        return self.parseArgsIterator(&iterator);
    }

    pub fn parseArgsIterator(self: *Self, iterator: anytype) !ArgumentNamespace {
        var namespace: ArgumentNamespace = try ArgumentNamespace.init(self.allocator, self.options);
        errdefer namespace.deinit();

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
            o.deinit(self.allocator);
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

test "ArgumentParser deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var parser = ArgumentParser.init(allocator);
    defer parser.deinit();

    try parser.addPositionalArgument("cmd", "positional1", true);
    try parser.addBoolArgument("f", "force", false);
    try parser.addValueArgument("o", "outfile", true);
    try parser.addPositionalArgument("p1", "positional1", true);
    try parser.addPositionalArgument("p2", "positional2", true);

    var args = try parser.parseArgs("ls -f --outfile filename pos1 pos2");

    args.deinit();
}

test "ArgumentParser test argParse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var parser = ArgumentParser.init(allocator);
    defer parser.deinit();

    try parser.addPositionalArgument("cmd", null, true);
    try parser.addBoolArgument("f", "force", false);
    try parser.addValueArgument("o", "outfile", true);
    try parser.addPositionalArgument("p1", "positional1", true);
    try parser.addPositionalArgument("p2", "positional2", true);

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

    // test positionals
    try std.testing.expectEqualStrings(args.get("p1").value(), "pos1");
    try std.testing.expectEqualStrings(args.get("p2").value(), "pos2");
}
