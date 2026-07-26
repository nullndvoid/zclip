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

const AppConfig = @import("Config.zig");
pub const Identity = @import("network/Identity.zig");
const NoiseSession = @import("network/NoiseSession.zig");
const Packet = @import("network/Packet.zig");
const Repo = @import("Repo.zig");
const util = @import("util.zig");

const log = std.log.scoped(.net);

pub const PeerMap = std.StringHashMap([]const u8);

io: Io,
alloc: Allocator,
server: Io.net.Server,
tasks: Io.Group,
start_task: Io.Future(void),
// /// Mapping from public keys to nicknames. If unexpected peers are found we can
// /// warn the user and drop the connection.
// peers: PeerMap,
// /// A set of nicknames in the config.
// nicks: std.StringHashMap(void),
// /// Peers that this machine should attempt to connect to first.
// to_connect: []const Peer,
/// The list of peers this machine should attempt to connect to first.
connectable: []const Peer,
/// This daemon's identity.
identity: Identity,
/// The database connection.
repo: *Repo,

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

/// Returns a list of all peers that this daemon should attempt to connect to.
/// Caller should free returned slice when done with it.
///
/// TODO: Could be called again later if we notice a new peer in the database?
pub fn getConnectable(ident: Identity, peers: []const Peer, alloc: Allocator) ![]const Peer {
    var out = std.ArrayList(Peer).empty;

    for (peers) |p| {
        if (p.addr != null and std.mem.order(u8, &ident.public_key, &p.pubkey) == .gt)
            try out.append(alloc, p);
    }

    return try out.toOwnedSlice(alloc);
}

pub fn init(io: Io, alloc: Allocator, identity: Identity, repo: *Repo, config: Config) !Network {
    const connectable = try getConnectable(identity, config.peers, alloc);

    {
        var allocating = Io.Writer.Allocating.init(alloc);
        const writer = &allocating.writer;
        try config.bind_addr.format(writer);

        const ip = try allocating.toOwnedSlice();
        defer alloc.free(ip);

        log.debug("Starting listener on {s}", .{ip});
    }

    const server = try config.bind_addr.listen(io, .{
        .reuse_address = true,
    });

    return .{
        .io = io,
        .alloc = alloc,
        .server = server,
        .tasks = .init,
        .start_task = undefined,
        .connectable = connectable,
        .identity = identity,
        .repo = repo,
    };
}

const Backoff = struct {
    const delays_s = [_]i64{ 1, 3, 5, 10, 20, 30 };

    failed: bool = false,
    delay_idx: usize = 0,
    attempts: usize = 1,

    /// Sleeps for the current delay, then advances to the next one.
    fn wait(self: *Backoff, io: Io) error{Canceled}!void {
        try io.sleep(.fromSeconds(delays_s[self.delay_idx]), .real);
        if (self.delay_idx != delays_s.len - 1)
            self.delay_idx += 1;

        self.attempts += 1;
    }

    /// Jumps straight to the maximum delay.
    fn saturate(self: *Backoff) void {
        self.delay_idx = delays_s.len - 1;
    }

    fn maxDelaySeconds() i64 {
        return delays_s[delays_s.len - 1];
    }
};

fn connectWithBackoff(self: *Network, addr: Io.net.IpAddress, peer: Peer, backoff: *Backoff) error{Canceled}!Io.net.Stream {
    while (true) {
        return addr.connect(self.io, .{ .mode = .stream }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                if (!backoff.failed) {
                    backoff.failed = true;
                    log.warn("Cannot reach `{s}`. Retrying...", .{peer.nickname});
                } else {
                    log.debug("Cannot reach `{s}`. Attempt {d}. Retrying...", .{ peer.nickname, backoff.attempts });
                }

                try backoff.wait(self.io);
                continue;
            },
        };
    }
}

/// Attempts to connect to a peer, retrying with backoff, then services the
/// connection until it closes. Only fails on cancellation; anything fatal for
/// this one peer is logged and gives up quietly.
fn connectToPeer(self: *Network, peer: Peer) error{Canceled}!void {
    var addr = Io.net.IpAddress.parseLiteral(peer.addr.?) catch |err| {
        log.err("Invalid address `{s}` for peer `{s}`: {t}. Not connecting.", .{ peer.addr.?, peer.nickname, err });
        return;
    };
    if (addr.getPort() == 0) addr.setPort(DEFAULT_NET_PORT);

    var backoff = Backoff{};

    while (true) {
        const stream = try self.connectWithBackoff(addr, peer, &backoff);
        var conn_arena = Arena.init(self.alloc);
        defer conn_arena.deinit();

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;

        var sock_rdr = stream.reader(self.io, &read_buf);
        var sock_writer = stream.writer(self.io, &write_buf);

        const rdr = &sock_rdr.interface;
        const writer = &sock_writer.interface;

        var session = NoiseSession.init(
            self.io,
            conn_arena.allocator(),
            rdr,
            writer,
            self.identity,
            &peer.pubkey,
            self.repo,
        ) catch |err| switch (err) {
            error.PeerDoesNotHoldPubkey => {
                stream.close(self.io);

                // The remote peer might fix their config, so keep retrying at
                // the maximum interval.
                if (!backoff.failed) {
                    log.warn("Peer `{s}` does not have this machines public key. Copy the following line to your peers config. Will retry every {d}s", .{ peer.nickname, Backoff.maxDelaySeconds() });
                    const b64_pk = util.encodeKey(self.identity.public_key);
                    log.info("pubkey = {s}", .{b64_pk});
                } else {
                    log.debug("Peer `{s}` still does not have this machines public key. Attempt {d}. Retrying soon...", .{ peer.nickname, backoff.attempts });
                }

                backoff.failed = true;
                backoff.saturate();
                try backoff.wait(self.io);
                continue;
            },
            else => {
                log.err("Noise handshake with peer `{s}` failed: {t}. Closing the connection and giving up.", .{ peer.nickname, err });
                stream.close(self.io);
                return;
            },
        };

        defer session.deinit();
        defer stream.close(self.io);

        self.processPackets(rdr, writer, &session) catch |err| {
            log.err("Processing packets failed. Reason: {t}", .{err});
        };

        return;
    }
}

/// Starts the Network workers. Blocking. May be cancelled as required.
pub fn start(self: *Network) void {
    if (self.connectable.len >= 1) {
        log.debug("Sending outbound connection requests to {d} peers", .{self.connectable.len});
    }

    for (self.connectable) |connectable| {
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
    self.alloc.free(self.connectable);
}

/// The peer has our pubkey already. Set in the configs out of band. So it should encrypt a message.
fn handleConnectionRw(self: *Network, rdr: *Io.Reader, writer: *Io.Writer) !void {
    // The peer connecting is initiator. Setup a noise session.
    var conn_arena = Arena.init(self.alloc);
    defer conn_arena.deinit();

    var session = NoiseSession.init(
        self.io,
        conn_arena.allocator(),
        rdr,
        writer,
        self.identity,
        null,
        self.repo,
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
    var packet_arena = Arena.init(self.alloc);
    defer packet_arena.deinit();

    while (true) {
        defer _ = packet_arena.reset(.retain_capacity);

        const packet = session.recvT(Packet, rdr, packet_arena.allocator()) catch |err| {
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

/// Used internally.
pub const Peer = struct {
    /// Peers public key. This is decoded from Base64.
    pubkey: [32]u8,

    /// A nickname for the remote peer.
    nickname: []const u8,

    /// The IP address of the remote peer. Null if the remote should only
    /// connect to this one.
    addr: ?[]const u8,

    /// A (locally) unique ID for the peer.
    /// Globally unique IDs could be generated using a hash of one's own public
    /// key.
    id: u64 = 0,
};
