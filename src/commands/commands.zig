const std = @import("std");

const LsMod = @import("ls.zig");
pub const Ls = LsMod.ls;

pub const CommandArgIterator = std.process.ArgIteratorGeneral(.{ .comments = true });
