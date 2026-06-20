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

const Daemon = @This();

opts: Opts,
arena: *ArenaAllocator,
io: Io,
clipboard: ?zclip.Clipboard,
server: ?Io.net.Server,
select_tasks: ?Io.Select(TaskResults),
select_tasks_buf: [1]TaskResults,

const TaskResults = union(enum) {
    unix: void,
    // Does not matter yet.
    inet: anyerror!void,
};

const log = std.log.scoped(.Daemon);

pub const Opts = struct {
    clipboard: zclip.Clipboard.Config = .{},
    socket_path: []const u8,
};

fn acceptConnections(io: Io, server: *Io.net.Server) void {
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

        group.concurrent(io, handleConnection, .{ io, stream }) catch unreachable;
    }
}

fn handleConnection(io: Io, stream: Io.net.Stream) !void {
    _ = io; // autofix
    _ = stream; // autofix
}

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

/// Starts the daemon worker, blocking. May be cancelled by a signal. See signal handling in `main.zig`.
///
/// TODO: Make this select between internet stuff and unix socket stuff.
pub fn start(self: *Daemon) !void {
    self.clipboard = try zclip.Clipboard.init(
        self.io,
        self.arena,
        self.opts.clipboard,
    );
    var addr = try Io.net.UnixAddress.init(self.opts.socket_path);
    self.server = try addr.listen(self.io, .{});

    self.select_tasks = .init(self.io, &self.select_tasks_buf);

    try self.select_tasks.?.concurrent(.unix, acceptConnections, .{ self.io, &self.server.? });

    _ = self.select_tasks.?.await() catch return;
}

pub fn deinit(self: *Daemon) void {
    if (self.select_tasks) |*select_tasks| {
        select_tasks.cancelDiscard();
        self.select_tasks = null;
    }
    if (self.server) |*server| {
        server.deinit(self.io);
        self.server = null;
    }
    if (self.clipboard) |*clipboard| {
        clipboard.deinit();
        self.clipboard = null;
    }
}
