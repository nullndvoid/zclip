//! High-level manager for the clipboard.

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;

const Backend = @import("root.zig").Backend;
const Clipping = @import("clipping.zig");

const Clipboard = @This();
arena: ArenaAllocator,
backend: Backend,

pub fn init(io: Io, arena: ArenaAllocator) !Clipboard {
    const backend = try Backend.init(io, arena.allocator());

    return .{
        .arena = arena,
        .backend = backend,
    };
}
