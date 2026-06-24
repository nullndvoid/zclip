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
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const zclip = @import("zclip");

const Network = @import("Network.zig");
const UnixSocket = @import("UnixSocket.zig");

const Daemon = @This();

opts: Opts,
arena: *ArenaAllocator,
io: Io,
clipboard: ?*zclip.Clipboard,
server: ?Io.net.Server,
select_tasks: ?Io.Select(TaskResults),
select_tasks_buf: [2]TaskResults,

const TaskResults = union(enum) {
    unix: void,
    inet: void,
};

const log = std.log.scoped(.Daemon);

pub const Opts = struct {
    clipboard: zclip.Clipboard.Config = .{},
    socket_path: []const u8,
    inet: Network.Config = .{},
};

pub fn init(io: Io, arena: *ArenaAllocator, opts: Opts) Daemon {
    return .{
        .io = io,
        .arena = arena,
        .opts = opts,
        .clipboard = null,
        .server = null,
        .select_tasks = null,
        .select_tasks_buf = undefined,
    };
}

fn clipCallback(clip: *zclip.Clip, _: *void) anyerror!void {
    if (!clip.is_text) return;

    log.debug("Got clip {s}", .{clip.data});
}

/// Starts the daemon worker, blocking. May be cancelled by a signal. See signal handling in `main.zig`.
pub fn start(self: *Daemon) !void {
    self.clipboard = try zclip.Clipboard.init(
        self.io,
        self.arena,
        self.opts.clipboard,
    );

    self.clipboard.?.setOnClip(void, clipCallback, @constCast(&{}));

    var addr = try Io.net.UnixAddress.init(self.opts.socket_path);
    self.server = try addr.listen(self.io, .{});

    var net = try Network.init(self.io, self.arena, self.opts.inet);
    defer net.deinit();

    self.select_tasks = .init(self.io, &self.select_tasks_buf);
    defer self.select_tasks.?.cancelDiscard();

    try self.select_tasks.?.concurrent(.unix, UnixSocket.acceptConnections, .{
        self.io,
        &self.server.?,
        self.clipboard.?,
    });

    try self.select_tasks.?.concurrent(.inet, Network.start, .{
        &net,
    });

    log.info("Listening on UNIX socket and TCP :{d}.", .{
        self.opts.inet.bind_addr.getPort(),
    });

    _ = try self.select_tasks.?.await();
}

pub fn deinit(self: *Daemon) void {
    if (self.select_tasks) |*select_tasks| {
        select_tasks.cancelDiscard();
        self.select_tasks = null;
    }
    if (self.server) |*server| {
        server.deinit(self.io);
        self.server = null;

        const path = self.arena.allocator().dupeSentinel(u8, self.opts.socket_path, 0) catch unreachable;
        defer self.arena.allocator().free(path);
        if (@import("builtin").os.tag != .windows) {
            if (std.c.unlink(path) == -1) {
                log.err("Failed to unlink socket file! Please delete it manually at {s}", .{self.opts.socket_path});
            }
        }
    }
    if (self.clipboard) |clipboard| {
        clipboard.deinit();
        self.clipboard = null;
    }
}
