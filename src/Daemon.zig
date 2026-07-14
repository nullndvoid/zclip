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

const zclip = @import("clipboard");

const Clipboard = zclip.Clipboard;
const Clip = zclip.Clip;

const Config = @import("Config.zig");
const Network = @import("Network.zig");
const Repo = @import("Repo.zig");
const UnixSocket = @import("UnixSocket.zig");

const Daemon = @This();

opts: Opts,
alloc: Allocator,
io: Io,
start_arena: std.heap.ArenaAllocator,
clipboard: ?*Clipboard,
select_tasks: ?Io.Select(TaskResults),
select_tasks_buf: [2]TaskResults,
identity: Network.Identity,
repo: Repo,

const TaskResults = union(enum) {
    unix: void,
    inet: void,
};

const log = std.log.scoped(.Daemon);

pub const Opts = struct {
    clipboard: Clipboard.Config = .{},
    socket_path: []const u8,
    inet: Network.Config = .{},
    data_dir: []const u8,
};

pub fn init(io: Io, alloc: Allocator, identity: Network.Identity, opts: Opts) Daemon {
    return .{
        .io = io,
        .alloc = alloc,
        .opts = opts,
        .clipboard = null,
        .select_tasks = null,
        .select_tasks_buf = undefined,
        .identity = identity,
        .repo = undefined,
        .start_arena = std.heap.ArenaAllocator.init(alloc),
    };
}

fn clipCallback(clip: *Clip, _: *void) anyerror!void {
    if (!clip.is_text) return;

    log.debug("Got clip {s}", .{clip.data});
}

/// Starts the daemon worker, blocking. May be cancelled by a signal. See signal handling in `main.zig`.
pub fn start(self: *Daemon) !void {
    // The clipboard outlives this function (it is torn down in `deinit`),
    // so it must not be backed by a stack-local arena.
    self.clipboard = try Clipboard.init(
        self.io,
        &self.start_arena,
        self.opts.clipboard,
    );

    self.clipboard.?.setOnClip(void, clipCallback, @constCast(&{}));

    const repo = try Repo.init(self.opts.data_dir, self.alloc);
    self.repo = repo;
    defer self.repo.deinit();

    var net = try Network.init(self.io, self.alloc, self.identity, &self.repo, self.opts.inet);
    defer net.deinit();

    self.select_tasks = .init(self.io, &self.select_tasks_buf);
    defer self.select_tasks.?.cancelDiscard();

    var unix = try UnixSocket.init(
        self.io,
        self.clipboard.?,
        self.alloc,
        self.opts.socket_path,
        self.identity,
        &self.repo,
    );
    defer unix.deinit();

    try self.select_tasks.?.concurrent(.unix, UnixSocket.start, .{&unix});

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

    if (self.clipboard) |clipboard| {
        clipboard.deinit();
        self.clipboard = null;
    }

    self.start_arena.deinit();
}
