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

const Network = @import("Network.zig");
const UnixSocket = @import("UnixSocket.zig");
const Command = UnixSocket.Command;
const CommandType = UnixSocket.CommandType;

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
    DaemonError,
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
    const reply = try self.sendCommand(.GetPeers);

    switch (reply) {
        .Peers => |peers| {
            return peers;
        },
        else => unreachable,
    }
}

// This is not base64 encoded. You should do this as needed.
pub fn getPubkey(self: *Client) ClientError![32]u8 {
    const reply = try self.sendCommand(.GetPubkey);

    switch (reply) {
        .Pubkey => |pubkey| {
            return pubkey.pubkey;
        },
        else => unreachable,
    }
}

/// Adds a peer to the daemon, with given ID. `force` overwrites if already exists.
pub fn addPeer(self: *Client, peer: Network.Peer, force: bool) ClientError!void {
    _ = try self.sendCommand(.{ .PostPeer = .{ .peer = peer, .force = force } });
}

/// Removes a peer from the daemon by ID.
pub fn removePeer(self: *Client, id: u64) ClientError!void {
    _ = try self.sendCommand(.{ .RemovePeer = .{ .id = id } });
}

/// Edits a peer by `peer_id`. Fields left unset in `edit_params` will not be
/// unset or updated.
pub fn editPeer(self: *Client, peer_id: u64, edit_params: UnixSocket.EditPeerParams) ClientError!void {
    _ = try self.sendCommand(.{
        .EditPeer = .{ .id = peer_id, .params = edit_params },
    });
}

fn sendCommand(self: *Client, command: Command) !Command {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = self.stream.reader(self.io, &read_buf);
    var sock_writer = self.stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    return try self.sendCommandRw(rdr, writer, command);
}

fn sendCommandRw(self: *Client, rdr: *Io.Reader, writer: *Io.Writer, command: Command) ClientError!Command {
    switch (command) {
        .Clip, .Pubkey, .Peers, .Ok, .DaemonError => return error.ServerCommand,
        else => {},
    }

    const resp_tag: CommandType = switch (command) {
        .GetPubkey => .Pubkey,
        .GetPeers => .Peers,
        else => .Ok,
    };

    UnixSocket.writeCommandFramed(writer, self.arena.allocator(), command) catch |err| {
        log.err("Sending command {t} failed. Reason: {t}", .{ command, err });

        return error.WriteFailed;
    };

    var ev = Io.Event.unset;

    var future = try self.io.concurrent(readResponseHelper, .{ self, rdr, resp_tag, &ev });
    ev.waitTimeout(
        self.io,
        .{
            .duration = .{
                .raw = .fromMilliseconds(200),
                .clock = .awake,
            },
        },
    ) catch |err| switch (err) {
        error.Timeout => {
            log.err("Wait for daemon response timed out.", .{});
            return error.ResponseTimedOut;
        },
        error.Canceled => |e| return e,
    };

    const cmd = future.await(self.io) catch |err| {
        if (err == error.Canceled) return err;

        log.err("Failed to read daemon response. Reason: {t}", .{err});

        return err;
    };

    return cmd;
}

fn readResponseHelper(self: *Client, rdr: *Io.Reader, expected_tag: CommandType, ev: *Io.Event) ClientError!Command {
    defer ev.set(self.io);

    const reply = UnixSocket.readFramedCommand(rdr, self.arena.allocator(), .{}) catch |err| {
        log.err("Failed to read reply from daemon. Reason: {t}", .{err});

        return error.ReadFailed;
    };

    const tag = std.meta.activeTag(reply);

    switch (reply) {
        .DaemonError => |err| {
            log.err("Daemon errored with message \"{s}\"", .{err});

            return error.DaemonError;
        },
        else => {},
    }

    if (tag != expected_tag) {
        log.err("Got unexpected reply from daemon. Expected {s} but got {s}", .{ @tagName(expected_tag), @tagName(tag) });

        return error.InvalidDaemonReply;
    }

    return reply;
}
