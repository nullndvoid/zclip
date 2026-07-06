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

const serde = @import("serde");
const zclip = @import("zclip");

const Network = @import("Network.zig");

const log = std.log.scoped(.UNIX);

const UnixSocket = @This();

pub const PublicKey = struct {
    pubkey: [32]u8,
};

pub const Command = union(enum) {
    /// Client wants to manually post a clip to the Daemon.
    PostClip: zclip.Clip,
    /// Daemon recieved a clip from remote peer or this machine.
    Clip: zclip.Clip,
    /// Client sends this to ask for local public key.
    GetPubkey,
    Pubkey: PublicKey,
};

clipboard: *zclip.Clipboard,
io: Io,
alloc: Allocator,
server: Io.net.Server,
tasks: Io.Group,
start_task: Io.Future(void),
socket_path: []const u8,

pub fn init(io: Io, clipboard: *zclip.Clipboard, alloc: Allocator, socket_path: []const u8) !UnixSocket {
    var addr = try Io.net.UnixAddress.init(socket_path);
    const server = try addr.listen(io, .{});

    return .{
        .io = io,
        .clipboard = clipboard,
        .alloc = alloc,
        .server = server,
        .tasks = .init,
        .start_task = undefined,
        .socket_path = socket_path,
    };
}

/// Blocking.
pub fn start(self: *UnixSocket) void {
    self.start_task = self.io.concurrent(acceptConnections, .{self}) catch unreachable;
    log.debug("Started accepting connections", .{});
    _ = self.start_task.await(self.io);
    log.debug("No longer accepting connections", .{});
}

pub fn deinit(self: *UnixSocket) void {
    self.tasks.cancel(self.io);
    self.server.deinit(self.io);

    const path = self.alloc.dupeSentinel(u8, self.socket_path, 0) catch unreachable;
    defer self.alloc.free(path);
    if (@import("builtin").os.tag != .windows) {
        if (std.c.unlink(path) == -1) {
            log.err("Failed to unlink socket file! Please delete it manually at {s}", .{self.socket_path});
        }
    }
}

pub fn acceptConnections(self: *UnixSocket) void {
    var group = Io.Group.init;

    defer group.cancel(self.io); // TODO: Send a Stop message and await instead.

    while (true) {
        const stream = self.server.accept(self.io) catch |err| {
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

        group.concurrent(self.io, handleConnection, .{ self, stream }) catch unreachable;
    }
}

/// A UNIX socket connection sends commands back and forth.
///
/// Commands are prefixed by their Content-Size, this does not include the Content-Size (u64) itself.
/// Commands are all sent in network (big endian) byte ordering.
fn handleConnection(self: *UnixSocket, stream: Io.net.Stream) !void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = stream.reader(self.io, &read_buf);
    var sock_writer = stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    var future = self.io.concurrent(handleConnectionRw, .{ self, rdr, writer }) catch unreachable;
    _ = future.await(self.io) catch |err| {
        log.err("handleConnectionRw errored with: {t}", .{err});
    };

    stream.shutdown(self.io, .both) catch |err| {
        switch (err) {
            error.Canceled => return,
            else => {},
        }

        log.err("Failed to shutdown UNIX stream. Reason: {t}", .{err});
    };
}

fn handleConnectionRw(self: *UnixSocket, rdr: *Io.Reader, writer: *Io.Writer) !void {
    _ = writer; // autofix
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    var allocating = Io.Writer.Allocating.init(self.alloc);
    defer allocating.deinit();

    const json_writer = &allocating.writer;

    while (true) {
        const command = try serde.msgpack.fromReader([]const u8, arena.allocator(), rdr);
        try serde.json.toPrettyWriter(json_writer, command, .{});

        var command_json = json_writer.toArrayList();
        defer command_json.deinit(self.alloc);

        log.debug("Got command {s}", .{command_json.items});
    }
}

fn clipCallback(clip: *zclip.Clip, _: *void) anyerror!void {
    if (!clip.is_text) return;

    log.debug("Got clip {s}", .{clip.data});
}
