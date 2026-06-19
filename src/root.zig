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

//! A library for management of the system clipboard, as well as
//! networking routines for usage in my consuming apps.

const std = @import("std");
const Io = std.Io;

const opts = @import("options");

pub const Clip = @import("Clip.zig");
pub const Clipboard = @import("Clipboard.zig");

pub const Backend = switch (opts.platform) {
    // TODO: Select X11/Wayland at runtime.
    .wayland => @import("Wayland.zig"),
    .windows => @import("Windows.zig"),
};

/// Lives as long as the Clipboard does, created by Clipboard and passed into Backend?
pub const ClipQueue = struct {
    io: Io,
    queue: Io.Queue(Clip),
    queue_buf: []Clip,

    pub const Config = struct {
        /// We don't expect much lag between reads and writes.
        buffer_size: usize = 5,
    };

    pub fn init(io: Io, gpa: std.mem.Allocator, config: ClipQueue.Config) !ClipQueue {
        const queue_buf = try gpa.alloc(Clip, config.buffer_size);
        const queue = Io.Queue(Clip).init(queue_buf);

        return .{
            .io = io,
            .queue = queue,
            .queue_buf = queue_buf,
        };
    }

    /// Close the queue so we can retrieve elements. Idempotent.
    pub fn close(self: *ClipQueue) void {
        self.queue.close(self.io);
    }

    pub fn deinit(self: *ClipQueue, gpa: std.mem.Allocator) void {
        self.queue.close(self.io);
        gpa.free(self.queue_buf);
    }
};

test {
    std.testing.refAllDecls(@This());
}
