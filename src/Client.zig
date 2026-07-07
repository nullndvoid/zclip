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

//! Client to talk to the daemon over UNIX sockets.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const serde = @import("serde");

const Command = @import("UnixSocket.zig").Command;
const CommandType = @import("UnixSocket.zig").CommandType;

const log = std.log.scoped(.Client);

const Client = @This();

pub const ClientError = error{
    /// Set when client tries to send a server command. This is mostly here in case I
    /// accidentally do this in calling code.
    ServerCommand,
    ReadFailed,
    WriteFailed,
};

pub const Opts = struct {
    socket_path: []const u8,
};

opts: Opts,
arena: *ArenaAllocator,
io: Io,
stream: Io.net.Stream,

/// Do not call deinit on the arena!
pub fn init(io: Io, arena: *ArenaAllocator, opts: Opts) !Client {
    const addr = try std.Io.net.UnixAddress.init(opts.socket_path);
    const stream = addr.connect(io) catch |err| {
        log.err("Could not connect to UNIX socket. Reason: {t}", .{err});

        return err;
    };

    return .{
        .io = io,
        .arena = arena,
        .opts = opts,
        .stream = stream,
    };
}

pub fn deinit(self: *Client) void {
    self.stream.shutdown(self.io, .both) catch {};
    self.arena.deinit();
}

pub fn sendCommand(self: *Client, command: Command) !void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = self.stream.reader(self.io, &read_buf);
    var sock_writer = self.stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    try self.sendCommandRw(rdr, writer, command);
}

fn sendCommandRw(self: *Client, rdr: *Io.Reader, writer: *Io.Writer, command: Command) ClientError!void {
    _ = rdr; // autofix
    switch (command) {
        .Clip, .Pubkey => return error.ServerCommand,
        else => {},
    }

    const resp_tag: ?CommandType = switch (command) {
        .GetPubkey => .Pubkey,
        else => null,
    };

    serde.msgpack.toWriter(self.arena.allocator(), writer, command) catch |err| {
        log.err("Sending command {t} failed. Reason: {t}", .{ command, err });

        return error.WriteFailed;
    };
    if (resp_tag == null) return;

    // TODO: Have a timeout.

    // const reply = serde.msgpack.fromReader(Command, self.arena.allocator(), rdr) catch |err| {
    //     log.err("Failed to read reply from daemon. Reason: {t}", .{err});

    //     return error.ReadFailed;
    // };
    // const tag = std.meta.activeTag(reply);

    // if (tag != resp_tag.?) {
    //     log.err("Got unexpected reply from daemon. Expected {s} but got {s}", .{ @tagName(resp_tag.?), @tagName(tag) });
    // }
}
