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

const UnixSocket = @import("UnixSocket.zig");
const Command = UnixSocket.Command;
const CommandType = UnixSocket.CommandType;
const Network = @import("Network.zig");

const log = std.log.scoped(.Client);

const Client = @This();

pub const ClientError = error{
    /// Set when client tries to send a server command. This is mostly here in case I
    /// accidentally do this in calling code.
    ServerCommand,
    ReadFailed,
    WriteFailed,
    ResponseTimedOut,
    MissingResponse,
    InvalidDaemonReply,
} || Io.ConcurrentError || Io.Cancelable;

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
        log.err("Is the daemon running? `zclip daemon`, or start the systemd service.", .{});

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

/// Gets a list of `Peer`'s from the daemon.
pub fn listPeers(self: *Client) ClientError![]const Network.Peer {
    const reply = try self.sendCommand(.GetPeers) orelse return error.MissingResponse;

    switch (reply) {
        .Peers => |peers| {
            return peers;
        },
        else => {
            return error.InvalidDaemonReply;
        },
    }
}

fn sendCommand(self: *Client, command: Command) !?Command {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = self.stream.reader(self.io, &read_buf);
    var sock_writer = self.stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    return try self.sendCommandRw(rdr, writer, command);
}

const SelectTask = union(enum) {
    timer: Io.Cancelable!void,
    read: ClientError!Command,
};

fn sendCommandRw(self: *Client, rdr: *Io.Reader, writer: *Io.Writer, command: Command) ClientError!?Command {
    switch (command) {
        .Clip, .Pubkey, .Peers => return error.ServerCommand,
        else => {},
    }

    const resp_tag: ?CommandType = switch (command) {
        .GetPubkey => .Pubkey,
        .GetPeers => .Peers,
        else => null,
    };

    UnixSocket.writeCommandFramed(writer, self.arena.allocator(), command) catch |err| {
        log.err("Sending command {t} failed. Reason: {t}", .{ command, err });

        return error.WriteFailed;
    };

    if (resp_tag == null) return null;

    var select_tasks: [2]SelectTask = undefined;
    var select = Io.Select(SelectTask).init(self.io, &select_tasks);

    try select.concurrent(.read, readResponseHelper, .{ self, rdr, resp_tag.? });
    try select.concurrent(.timer, Io.sleep, .{
        self.io,
        .fromMilliseconds(200),
        .real,
    });

    defer select.cancelDiscard();

    const res = try select.await();
    switch (res) {
        .read => |rd| {
            const cmd = rd catch |err| {
                log.err("Failed to read daemon response. Reason: {t}", .{err});

                return err;
            };

            return cmd;
        },
        .timer => |resp| {
            resp catch |err| {
                switch (err) {
                    error.Canceled => return err,
                }
            };

            log.err("Wait for daemon response timed out.", .{});

            return error.ResponseTimedOut;
        },
    }
}

fn readResponseHelper(self: *Client, rdr: *Io.Reader, expected_tag: CommandType) !Command {
    const reply = UnixSocket.readFramedCommand(rdr, self.arena.allocator(), .{}) catch |err| {
        log.err("Failed to read reply from daemon. Reason: {t}", .{err});

        return error.ReadFailed;
    };

    const tag = std.meta.activeTag(reply);

    if (tag != expected_tag) {
        log.err("Got unexpected reply from daemon. Expected {s} but got {s}", .{ @tagName(expected_tag), @tagName(tag) });
    }

    return reply;
}
