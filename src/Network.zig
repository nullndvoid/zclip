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

//! Networking code for zclip peers.

const std = @import("std");
const Io = std.Io;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Box = std.crypto.nacl.Box;
const Ed25519 = std.crypto.sign.Ed25519;
const b64 = std.base64.standard;

const Serde = @import("serde");

pub const Identity = @import("network/Identity.zig");
const NoiseSession = @import("network/NoiseSession.zig");
const Packet = @import("network/Packet.zig");

const log = std.log.scoped(.net);

pub const PeerMap = std.StringHashMap([]const u8);

io: Io,
arena: *Arena,
server: Io.net.Server,
tasks: Io.Group,
start_task: Io.Future(void),
/// Mapping from public keys to nicknames. If unexpected peers are found we can
/// warn the user and drop the connection.
peers: PeerMap,
/// A set of nicknames in the config.
nicks: std.StringHashMap(void),
/// This daemon's identity.
identity: Identity,
/// Peers that this machine should attempt to connect to first.
to_connect: []const Peer,

const Network = @This();

pub const DEFAULT_NET_PORT = 48500;

pub const Config = struct {
    bind_addr: Io.net.IpAddress = .{ .ip4 = .unspecified(DEFAULT_NET_PORT) },
    peers: []Peer = &.{},
};

pub fn parseIp(ip: []const u8) !Io.net.IpAddress {
    var addr = try Io.net.IpAddress.parseLiteral(ip);
    if (addr.getPort() == 0) {
        addr.setPort(DEFAULT_NET_PORT);
    }

    return addr;
}

/// Alloc is assumed to use an arena.
fn collectPeers(identity: Identity, peers: []const Peer, alloc: Allocator) !struct {
    hashmap: PeerMap,
    set: std.StringHashMap(void),
    to_connect: []const Peer,
} {
    var hashmap = PeerMap.initContext(alloc, .{});
    var set = std.StringHashMap(void).init(alloc);
    var to_connect_al = std.ArrayList(Peer).empty;

    for (peers) |peer| {
        if (!peer.fixed)
            @panic("This is a bug. Peers public keys should be b64 decoded already.");
        try hashmap.put(peer.pubkey, peer.nickname);
        try set.put(peer.nickname, {});

        if (peer.addr != null and std.mem.order(u8, &identity.public_key, peer.pubkey) == .gt)
            try to_connect_al.append(alloc, peer);
    }

    return .{
        .hashmap = hashmap,
        .set = set,
        .to_connect = try to_connect_al.toOwnedSlice(alloc),
    };
}

pub fn init(io: Io, arena: *Arena, identity: Identity, config: Config) !Network {
    const peers = try collectPeers(identity, config.peers, arena.allocator());

    var allocating = Io.Writer.Allocating.init(arena.allocator());
    const writer = &allocating.writer;
    try config.bind_addr.format(writer);

    const ip = try allocating.toOwnedSlice();
    errdefer arena.allocator().free(ip);

    log.debug("Starting listener on {s}", .{ip});

    const server = try config.bind_addr.listen(io, .{
        .reuse_address = true,
    });

    return .{
        .io = io,
        .arena = arena,
        .server = server,
        .tasks = .init,
        .start_task = undefined,
        .nicks = peers.set,
        .peers = peers.hashmap,
        .identity = identity,
        .to_connect = peers.to_connect,
    };
}

/// Attempts to connect to a peer using some kind of exponential backoff.
fn connectToPeer(self: *Network, peer: Peer) !void {
    var addr = try Io.net.IpAddress.parseLiteral(peer.addr.?);
    if (addr.getPort() == 0) addr.setPort(DEFAULT_NET_PORT);
    var stream: Io.net.Stream = undefined;
    var failed: bool = false;
    const backoffs = [_]i64{
        1,
        3,
        5,
        10,
        20,
        30,
    };
    var backoff_idx: usize = 0;
    var attempts: usize = 1;

    while (true) {
        stream = addr.connect(self.io, .{ .mode = .stream }) catch |err| {
            switch (err) {
                error.Canceled => return,
                else => {
                    if (!failed) {
                        failed = true;
                        log.warn("Cannot reach `{s}`. Retrying...", .{peer.nickname});
                    } else {
                        log.debug("Cannot reach `{s}`. Attempt {d}. Retrying...", .{ peer.nickname, attempts });
                    }

                    try self.io.sleep(.fromSeconds(backoffs[backoff_idx]), .real);
                    if (backoff_idx != backoffs.len - 1)
                        backoff_idx += 1;

                    attempts += 1;

                    continue;
                },
            }
        };

        break;
    }

    attempts = 0;
    failed = false;

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = stream.reader(self.io, &read_buf);
    var sock_writer = stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    // Setup a noise session.
    var session: NoiseSession = undefined;

    while (true) {
        session = NoiseSession.init(
            self.io,
            self.arena.allocator(),
            rdr,
            writer,
            self.identity,
            &self.peers,
            null,
            .{
                .initiator = true,
            },
        ) catch |err| switch (err) {
            error.UnknownPeer => return,
            error.PeerDoesNotHoldPubkey => {
                // Since the remote peer might fix their config. Warn and jump to max increment.
                if (!failed) {
                    failed = true;
                    log.warn("Peer `{s}` does not have this machines public key. Copy the following line to your peers config. Will retry in 30s", .{peer.nickname});
                    const size = std.base64.standard.Encoder.calcSize(self.identity.public_key.len);
                    const buf = try self.arena.allocator().alloc(u8, size);
                    defer self.arena.allocator().free(buf);

                    const b64_pk = b64.Encoder.encode(buf, &self.identity.public_key);
                    log.info("pubkey = {s}", .{b64_pk});
                } else {
                    log.debug("Peer `{s}` still does not have this machines public key. Attempt {d}. Retrying soon...", .{ attempts, peer.nickname });
                }

                try self.io.sleep(.fromSeconds(backoffs[backoff_idx]), .real);
                if (backoff_idx != backoffs.len - 1)
                    backoff_idx += 1;

                attempts += 1;

                continue;
            },
            else => {
                log.err("Something went wrong with the Noise handshake :(. What: {t}", .{err});
                log.err("The connection will be closed.", .{});

                return;
            },
        };

        break;
    }

    attempts = 0;
    failed = false;

    defer session.deinit();

    try self.processPackets(rdr, writer, &session);
}

/// Starts the Network workers. Blocking. May be cancelled as required.
pub fn start(self: *Network) void {
    if (self.to_connect.len >= 1) {
        log.debug("Sending outbound connection requests to {d} peers", .{self.to_connect.len});
    }

    for (self.to_connect) |connectable| {
        self.tasks.concurrent(self.io, connectToPeer, .{ self, connectable }) catch unreachable;
    }

    self.start_task = self.io.concurrent(acceptConnections, .{self}) catch unreachable;
    log.debug("Started accepting connections", .{});
    _ = self.start_task.await(self.io);
    log.debug("No longer accepting connections", .{});
}

pub fn deinit(self: *Network) void {
    self.tasks.cancel(self.io);
    self.start_task.await(self.io);
    self.server.deinit(self.io);
}

/// The peer has our pubkey already. Set in the configs out of band. So it should encrypt a message.
fn handleConnectionRw(self: *Network, rdr: *Io.Reader, writer: *Io.Writer) !void {
    const alloc = self.arena.allocator();
    _ = alloc; // autofix

    // The peer connecting is initiator. Setup a noise session.
    var session = NoiseSession.init(
        self.io,
        self.arena.allocator(),
        rdr,
        writer,
        self.identity,
        &self.peers,
        null,
        .{
            .initiator = false,
        },
    ) catch |err| switch (err) {
        error.UnknownPeer, error.PeerDoesNotHoldPubkey => return,
        else => {
            log.err("Something went wrong with the Noise handshake :(. What: {t}", .{err});
            log.err("The connection will be closed.", .{});

            return;
        },
    };

    defer session.deinit();

    try self.processPackets(rdr, writer, &session);
}

fn processPackets(self: *Network, rdr: *Io.Reader, writer: *Io.Writer, session: *NoiseSession) !void {
    _ = writer; // autofix
    const alloc = self.arena.allocator();

    while (true) {
        const packet = session.recvT(Packet, rdr, alloc) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => {},
            }

            log.err("Could not read packet from peer `{s}`. Reason: {t}", .{ session.peer_nick, err });

            return err;
        };

        log.debug("Got packet! {any}", .{packet});
    }
}

fn handleConnection(self: *Network, stream: Io.net.Stream) void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = stream.reader(self.io, &read_buf);
    var sock_writer = stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    self.handleConnectionRw(rdr, writer) catch |err| {
        // switch (err) {
        //     error.Canceled => return,
        //     else => {},
        // }

        log.err("TCP connection handler errored. Reason: {t}", .{err});
    };

    stream.shutdown(self.io, .both) catch |err| {
        switch (err) {
            error.Canceled => return,
            else => {},
        }

        log.err("Failed to shutdown TCP stream. Reason: {t}", .{err});
    };
}

fn acceptConnections(self: *Network) void {
    defer self.tasks.cancel(self.io);

    while (true) {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.Canceled => {
                return;
            },
            else => {
                log.err("acceptConnections got error: {t}. Moving on...", .{err});
                continue;
            },
        };

        log.debug("Accepted inet connection from peer", .{});

        self.tasks.concurrent(self.io, handleConnection, .{ self, stream }) catch unreachable;
    }
}

pub const Peer = struct {
    /// Peers public key. Should be 32 bytes in length.
    pubkey: []const u8,

    /// A nickname for the remote peer.
    nickname: []const u8,

    /// The IP address of the remote peer. Null if the remote should only
    /// connect to this one.
    addr: ?[]const u8,

    fixed: bool = false,

    pub fn fix(self: *Peer, arena: *Arena) !void {
        if (self.fixed) return;

        const len = try b64.Decoder.calcSizeForSlice(self.pubkey);
        if (len != 32) return error.InvalidPubkeyLength;

        const pubkey: []u8 = try arena.allocator().alloc(u8, len);
        errdefer arena.allocator().free(pubkey);

        try b64.Decoder.decode(pubkey, self.pubkey);

        self.fixed = true;
        self.pubkey = pubkey;
    }
};
