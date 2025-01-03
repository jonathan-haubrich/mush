const std = @import("std");

const LsMod = @import("ls.zig");
pub const Ls = LsMod.ls;

pub const CommandargIterator = std.process.ArgIteratorGeneral(.{ .comments = true });
