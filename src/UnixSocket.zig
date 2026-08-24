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
const zclip = @import("clipboard");
const Clip = zclip.Clip;
const Clipboard = zclip.Clipboard;

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
    /// Client wants a peer removed by ID.
    RemovePeer,
    /// Client wants to edit a peer's details.
    EditPeer,
    /// Generic response if the daemon processed what was sent.
    Ok,
    /// Contains an error message for debugging.
    DaemonError,
};

pub const PostPeerPayload = struct { peer: Network.Peer, force: bool };
pub const RemovePeerPayload = struct { id: u64 };
pub const EditPeerParams = struct {
    clear_degraded: bool = false,
    pubkey: ?[]const u8 = null,
    nick: ?[]const u8 = null,
    host: ?[]const u8 = null,
    clear_host: bool = false,
};
pub const EditPeerPayload = struct { id: u64, params: EditPeerParams };

pub const Command = union(CommandType) {
    PostClip: Clip,
    Clip: Clip,
    GetPubkey,
    Pubkey: PublicKey,
    InvalidCommand,
    GetPeers,
    Peers: []const Network.Peer,
    PostPeer: PostPeerPayload,
    RemovePeer: RemovePeerPayload,
    EditPeer: EditPeerPayload,
    Ok,
    DaemonError: []const u8,
};

clipboard: *Clipboard,
io: Io,
alloc: Allocator,
server: Io.net.Server,
tasks: Io.Group,
socket_path: []const u8,
identity: Network.Identity,
repo: *Repo,
/// Owned and closed by Daemon. Broadcasts commands to Network.
commands: *Io.Queue(Network.Command),

pub fn init(
    io: Io,
    clipboard: *Clipboard,
    alloc: Allocator,
    socket_path: []const u8,
    identity: Network.Identity,
    repo: *Repo,
    commands: *Io.Queue(Network.Command),
) !UnixSocket {
    var addr = try Io.net.UnixAddress.init(socket_path);
    const server = addr.listen(io, .{}) catch |err| {
        switch (err) {
            error.AddressInUse => {
                log.err("Socket file is already in use! Please stop other running instances of the daemon!", .{});

                return err;
            },
            else => return err,
        }
    };

    return .{
        .io = io,
        .clipboard = clipboard,
        .alloc = alloc,
        .server = server,
        .tasks = .init,
        .socket_path = socket_path,
        .identity = identity,
        .repo = repo,
        .commands = commands,
    };
}

/// Blocking.
pub fn start(self: *UnixSocket) void {
    log.debug("Started accepting connections", .{});
    self.acceptConnections();
    log.debug("No longer accepting connections", .{});
}

pub fn deinit(self: *UnixSocket) void {
    self.tasks.cancel(self.io);
    self.server.deinit(self.io);

    Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {
        log.err("Failed to unlink socket file! Please delete it manually at {s}", .{self.socket_path});
    };
}

pub fn acceptConnections(self: *UnixSocket) void {
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

        self.tasks.concurrent(self.io, handleConnection, .{ self, stream }) catch |err| {
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
fn handleConnection(self: *UnixSocket, stream: Io.net.Stream) void {
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

/// Magic number is the length of our public keys when base64 encoded.
///
/// Validated by client but just in case we had some malicious or broken
/// program, or regressions in the client, we should check this server side.
///
/// This reads like a clanker wrote it. It did not.
const PUBKEY_LEN_B64 = 44;

fn handleConnectionRw(self: *UnixSocket, rdr: *Io.Reader, writer: *Io.Writer) !void {
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const reply_alloc = arena.allocator();

    while (true) {
        _ = arena.reset(.retain_capacity);

        const command = readFramedCommand(rdr, reply_alloc, .{}) catch |err| switch (err) {
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
            .GetPubkey => .{ .Pubkey = .{ .pubkey = self.identity.public_key } },
            .GetPeers => try self.handleGetPeers(reply_alloc),
            .EditPeer => |ep| try self.handleEditPeer(ep, reply_alloc),
            .PostPeer => |p| try self.handlePostPeer(p.peer, p.force, reply_alloc),
            .RemovePeer => |p| try self.handleRemovePeer(p.id),
            else => .Ok,
        };

        try writeCommandFramed(writer, reply_alloc, reply);
    }
}

fn handleGetPeers(self: *UnixSocket, alloc: Allocator) !Command {
    const peers = self.repo.getPeers(alloc) catch |err| {
        return .{ .DaemonError = @errorName(err) };
    };

    return .{ .Peers = peers };
}

fn handleEditPeer(self: *UnixSocket, payload: EditPeerPayload, alloc: Allocator) !Command {
    // Check the peer exists first.
    const exists = self.repo.peerExistsById(payload.id) catch |err| {
        const err_str = try alloc.print(
            "Peer ID {d}: failed to edit (tried checking peer exists). Why: {t}",
            .{ payload.id, err },
        );

        return .{ .DaemonError = err_str };
    };

    if (!exists) {
        const err_str = try alloc.print(
            "Peer ID {d} does not exist!",
            .{payload.id},
        );

        return .{ .DaemonError = err_str };
    }

    if (payload.params.clear_degraded) {
        self.repo.updatePeerDegraded(payload.id, null) catch |err| {
            const err_str = try alloc.print(
                "Peer ID {d}: failed to edit at --clear-degraded. Why: {t}",
                .{ payload.id, err },
            );

            return .{ .DaemonError = err_str };
        };
    }

    var host_set: bool = false;
    if (payload.params.clear_host) {
        // Perhaps the client CLI should warn if you provided both -i and --clear-host.
        self.repo.setPeerHostname(payload.id, payload.params.host) catch |err| {
            const err_str = try alloc.print(
                "Peer ID {d}: failed to edit at --clear-host. Why: {t}",
                .{ payload.id, err },
            );

            return .{ .DaemonError = err_str };
        };

        host_set = true;
    }

    if (!host_set and payload.params.host != null) {
        self.repo.setPeerHostname(payload.id, payload.params.host.?) catch |err| {
            const err_str = try alloc.print(
                "Peer ID {d}: failed to edit at --host. Why: {t}",
                .{ payload.id, err },
            );

            return .{ .DaemonError = err_str };
        };
    }

    if (payload.params.nick) |nick| {
        self.repo.setPeerNickname(payload.id, nick) catch |err| {
            const err_str = try alloc.print(
                "Peer ID {d}: failed to edit at --nick. Why: {t}",
                .{ payload.id, err },
            );

            return .{ .DaemonError = err_str };
        };
    }

    if (payload.params.pubkey) |pk| {
        if (pk.len != PUBKEY_LEN_B64) {
            return .{ .DaemonError = "public key had invalid length. Should be 44 bytes." };
        }

        self.repo.setPeerPubkey(payload.id, pk) catch |err| {
            const err_str = try alloc.print(
                "Peer ID {d}: failed to edit at --pubkey. Why: {t}",
                .{ payload.id, err },
            );

            return .{ .DaemonError = err_str };
        };
    }

    return .Ok;
}

fn handleRemovePeer(self: *UnixSocket, peer_id: u64) !Command {
    self.repo.removePeer(peer_id) catch |err| {
        return .{ .DaemonError = @errorName(err) };
    };

    self.commands.putOne(
        self.io,
        .{ .peer_rm = peer_id },
    ) catch |e| {
        log.warn(
            \\Removed peer with ID {d} but could not post command to Network. 
            \\Connection will not be terminated until you restart the daemon. Reason: {t}
        , .{ peer_id, e });
    };

    return .Ok;
}

fn handlePostPeer(self: *UnixSocket, peer: Network.Peer, force: bool, alloc: Allocator) !Command {
    var peer_copy = peer;

    // The DB stores pubkeys base64 encoded.
    const pubkey_b64 = util.encodeKey(peer.pubkey);

    var addr: []u8 = &.{};

    if (peer.host) |host| {
        addr = try alloc.print("{f}", .{host});
    }

    const id = self.repo.addPeer(.{
        .addr = if (peer.host) |_| addr else null,
        .nickname = peer.nickname,
        .pubkey = &pubkey_b64,
    }, force) catch |err| {
        return .{ .DaemonError = @errorName(err) };
    };

    // We should try to ignore errors here since we did commit to
    // DB, but I want to push an event to the Network handler to
    // tell it to start trying to connect to a new peer.
    errdefer comptime unreachable;

    peer_copy.id = id;
    self.commands.putOne(self.io, .{ .peer_add = peer_copy }) catch |e| {
        // TODO: Make this retryable with some kinda command?
        //       The real underlying issue is that we want a way for both sides to
        //       attempt to establish a connection at any time.
        log.warn(
            \\Added peer with ID {d} but could not post command to Network. 
            \\Connection will not be established until you restart the daemon. Reason: {t}
        , .{ id, e });
    };

    return .Ok;
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
