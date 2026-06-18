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

const std = @import("std");
const Io = std.Io;

const zclip = @import("zclip");
const Clip = zclip.Clip;

fn onRead(clip: Clip, _: *void) void {
    if (clip.is_text) {
        std.log.info("onRead got clipping: {s}", .{clip.data});
    } else {
        std.log.info(
            "onRead got clipping (MIME type = {s}) (length is {d})",
            .{ clip.mime_type, clip.data.len },
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var backend = try zclip.Backend.init(io, &arena);

    backend.setOnRead(void, onRead, @constCast(&{}));

    // For testing purposes, let's sleep for a bit, write to clipboard, and exit.
    try io.sleep(.fromMilliseconds(500), .real);

    const clip = Clip{
        .data = "Hello, world!",
        .is_text = true,
        .mime_type = "text/plain;charset=utf-8",
    };

    try backend.setClipboard(clip);

    // See if we read back our own clipping. If so, we want to write some internal
    // MIME type to allow us to ignore our own writes.
    try io.sleep(.fromSeconds(5), .real);

    defer backend.deinit();
}
