// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 J. Hinchliffe (nullndvoid)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.

//! Higher level clipboard management.

const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;

const zclip = @import("root.zig");
const Backend = zclip.Backend;
const Clip = zclip.Clip;
const ClipQueue = zclip.ClipQueue;

backend: *Backend,
clips: ?Clip = null,

const Clipboard = @This();

pub fn init(io: Io, arena: *ArenaAllocator) !Clipboard {
    const read_clip_queue = try arena.allocator().create(ClipQueue);
    read_clip_queue.* = try zclip.ClipQueue.init(
        io,
        arena.allocator(),
        .{ .buffer_size = 5 },
    );

    const backend = try Backend.init(io, arena, read_clip_queue);

    return .{
        .backend = backend,
    };
}

pub fn deinit(self: *Clipboard) void {
    self.backend.deinit();
}
