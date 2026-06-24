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

//! Unix socket code i.e. handlers for use in `Daemon.zig`. As well as related types.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const zclip = @import("zclip");

const Network = @import("Network.zig");

const log = std.log.scoped(.Daemon);

pub const Command = struct {
    content_length: u64,
    command: CommandInner,

    const CommandInner = union(enum) {
        /// Client wants to manually post a clip to the Daemon.
        PostClip: zclip.Clip,
        /// Daemon recieved a clip from remote peer or this machine.
        Clip: zclip.Clip,
    };
};

pub fn acceptConnections(io: Io, server: *Io.net.Server, clipboard: *zclip.Clipboard) void {
    var group = Io.Group.init;

    defer group.cancel(io); // TODO: Send a Stop message and await instead.

    while (true) {
        const stream = server.accept(io) catch |err| {
            switch (err) {
                error.Canceled => {
                    return;
                },
                else => {
                    log.err("acceptConnections, error accepting connection: {t}", .{err});
                    continue;
                },
            }
        };

        log.debug("Accepted UNIX socket connection", .{});

        group.concurrent(io, handleConnection, .{ io, stream, clipboard }) catch unreachable;
    }
}

/// A UNIX socket connection sends commands back and forth.
///
/// Commands are prefixed by their Content-Size, this does not include the Content-Size (u64) itself.
/// Commands are all sent in network (big endian) byte ordering.
fn handleConnection(io: Io, stream: Io.net.Stream, clipboard: *zclip.Clipboard) !void {
    _ = io; // autofix
    _ = stream; // autofix
    _ = clipboard; // autofix
    // clipboard.clips

}

fn clipCallback(clip: *zclip.Clip, _: *void) anyerror!void {
    if (!clip.is_text) return;

    log.debug("Got clip {s}", .{clip.data});
}
