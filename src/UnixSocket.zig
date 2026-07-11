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
const Repo = @import("Repo.zig");
const util = @import("util.zig");

const log = std.log.scoped(.UNIX);

const UnixSocket = @This();

pub const PublicKey = struct {
    pubkey: [32]u8,
};

pub const CommandType = enum {
    /// Client wants to manually post a clip to the Daemon.
    PostClip,
    /// Daemon recieved a clip from remote peer or this machine.
    Clip,
    /// Client sends this to ask for local public key.
    GetPubkey,
    /// Daemon replies with the local public key.
    Pubkey,
    /// Either side may issue this if the command recieved was invalid.
    InvalidCommand,
    /// Client wants the list of peers.
    GetPeers,
    /// Daemon returns the peer list.
    Peers,
    /// Client sends a new peer to add to the config.
    PostPeer,
    /// Generic response if the daemon processed what was sent.
    Ok,
    /// Contains an error message for debugging.
    DaemonError,
};

pub const PostPeerPayload = struct { peer: Network.Peer, force: bool };

pub const Command = union(CommandType) {
    PostClip: zclip.Clip,
    Clip: zclip.Clip,
    GetPubkey,
    Pubkey: PublicKey,
    InvalidCommand,
    GetPeers,
    Peers: []const Network.Peer,
    PostPeer: PostPeerPayload,
    Ok,
    DaemonError: []const u8,
};

clipboard: *zclip.Clipboard,
io: Io,
alloc: Allocator,
server: Io.net.Server,
tasks: Io.Group,
start_task: Io.Future(void),
socket_path: []const u8,
identity: Network.Identity,
repo: *Repo,

pub fn init(
    io: Io,
    clipboard: *zclip.Clipboard,
    alloc: Allocator,
    socket_path: []const u8,
    identity: Network.Identity,
    repo: *Repo,
) !UnixSocket {
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
        .identity = identity,
        .repo = repo,
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

    defer group.cancel(self.io);

    while (true) {
        const stream = self.server.accept(self.io) catch |err| {
            switch (err) {
                error.Canceled => {
                    return;
                },
                error.ConnectionAborted => continue,
                else => {
                    log.err("acceptConnections, error accepting connection: {t}", .{err});

                    return;
                },
            }
        };

        log.debug("Accepted UNIX socket connection", .{});

        group.concurrent(self.io, handleConnection, .{ self, stream }) catch |err| {
            switch (err) {
                error.ConcurrencyUnavailable => stream.close(self.io),
            }
        };
    }
}

/// A UNIX socket connection sends commands back and forth.
///
/// Commands are prefixed by their Content-Size, this does not include the Content-Size (u64) itself.
/// Commands are all sent in network (big endian) byte ordering.
fn handleConnection(self: *UnixSocket, stream: Io.net.Stream) !void {
    defer stream.close(self.io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = stream.reader(self.io, &read_buf);
    var sock_writer = stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    self.handleConnectionRw(rdr, writer) catch |err| {
        log.err("handleConnectionRw failed. Reason: {t}", .{err});
        if (sock_rdr.err) |e| log.err("Underlying stream read error: {t}", .{e});
        if (sock_writer.err) |e| log.err("Underlying stream write error: {t}", .{e});
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
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);

        const command = readFramedCommand(rdr, arena.allocator(), .{}) catch |err| switch (err) {
            // Client disconnected cleanly between commands.
            error.EndOfStream => return,
            error.TruncatedCommand => {
                log.err("Client disconnected mid-command.", .{});
                return err;
            },
            else => {
                log.err("Failed to read command. Reason: {t}", .{err});
                return err;
            },
        };

        const reply: Command = switch (command) {
            .GetPubkey => .{
                .Pubkey = .{
                    .pubkey = self.identity.public_key,
                },
            },
            .GetPeers => blk: {
                var cmd: Command = undefined;
                const peers = self.repo.getPeers() catch |err| {
                    cmd = .{ .DaemonError = @errorName(err) };
                    break :blk cmd;
                };
                cmd = .{ .Peers = peers };

                break :blk cmd;
            },
            .PostPeer => |p| blk: {
                const peer = p.peer;
                const force = p.force;

                var cmd: Command = undefined;

                // The DB stores pubkeys base64 encoded.
                const pubkey_b64 = util.base64encode(&peer.pubkey, arena.allocator()) catch |err| {
                    cmd = .{ .DaemonError = @errorName(err) };

                    break :blk cmd;
                };

                self.repo.addPeer(.{
                    .addr = peer.addr,
                    .nickname = peer.nickname,
                    .pubkey = pubkey_b64,
                }, force) catch |err| {
                    cmd = .{ .DaemonError = @errorName(err) };

                    break :blk cmd;
                };

                cmd = .Ok;

                break :blk cmd;
            },
            else => .Ok,
        };

        try writeCommandFramed(writer, arena.allocator(), reply);
    }
}

const MAX_CONTENT_LENGTH = 16 * 1024 * 1024;

const MAGIC = "zclip!";

const ReadConfig = struct {
    max_length: ?u64 = MAX_CONTENT_LENGTH,
};

/// You should consider using an arena to avoid leaking internal allocations,
/// or manually freeing things like slices.
///
/// Returns `error.EndOfStream` if the peer disconnected before sending a
/// length prefix (a clean disconnect), and `error.TruncatedCommand` if the
/// stream ended partway through a command.
pub fn readFramedCommand(rdr: *Io.Reader, alloc: Allocator, config: ReadConfig) !Command {
    var magic: [MAGIC.len]u8 = undefined;
    try rdr.readSliceAll(&magic);

    if (!std.mem.eql(u8, MAGIC, &magic)) return error.InvalidMagic;

    const content_length = try rdr.takeInt(u64, .big);

    if (config.max_length) |length| {
        if (content_length >= length) return error.CommandTooLong;
    }

    const bytes = try alloc.alloc(u8, content_length);
    defer alloc.free(bytes);

    rdr.readSliceAll(bytes) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedCommand,
        else => |e| return e,
    };

    const command = try serde.msgpack.fromSlice(Command, alloc, bytes);

    return command;
}

pub fn writeCommandFramed(writer: *Io.Writer, alloc: Allocator, command: Command) !void {
    const data = try serde.msgpack.toSlice(alloc, command);
    defer alloc.free(data);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u64, data.len, .big);
    try writer.writeAll(data);
    try writer.flush();
}

fn clipCallback(clip: *zclip.Clip, _: *void) anyerror!void {
    if (!clip.is_text) return;

    log.debug("Got clip {s}", .{clip.data});
}
