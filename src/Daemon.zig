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
clipboard: zclip.Clipboard,
server: *Io.net.Server,
unix_accept_task: Io.Future(void),

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
            log.err("acceptConnections, error accepting connection: {t}", .{err});
            continue;
        };

        log.debug("Accepted UNIX socket connection", .{});

        group.concurrent(io, handleConnection, .{ io, stream }) catch unreachable;
    }
}

fn handleConnection(io: Io, stream: Io.net.Stream) !void {
    _ = io; // autofix
    _ = stream; // autofix
}

pub fn init(io: Io, arena: *ArenaAllocator, opts: Opts) !Daemon {
    const clipboard = try zclip.Clipboard.init(io, arena, opts.clipboard);
    var addr = try Io.net.UnixAddress.init(opts.socket_path);

    const server = try arena.allocator().create(Io.net.Server);
    server.* = try addr.listen(io, .{});

    const task = try io.concurrent(acceptConnections, .{ io, server });

    return .{
        .io = io,
        .arena = arena,
        .opts = opts,
        .clipboard = clipboard,
        .server = server,
        .unix_accept_task = task,
    };
}

pub fn deinit(self: *Daemon) void {
    self.unix_accept_task.await(self.io);
    self.server.deinit(self.io);
    self.clipboard.deinit();
    self.arena.deinit();
}
