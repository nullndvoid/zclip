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

const Packet = @import("network/Packet.zig");

const log = std.log.scoped(.net);

const PeerMap = std.StringHashMap([]const u8);

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
fn collectPeers(peers: []const Peer, alloc: Allocator) !struct { hashmap: PeerMap, set: std.StringHashMap(void) } {
    var hashmap = PeerMap.initContext(alloc, .{});
    var set = std.StringHashMap(void).init(alloc);

    for (peers) |peer| {
        try hashmap.put(peer.pubkey, peer.nickname);
        try set.put(peer.nickname, {});
    }

    return .{
        .hashmap = hashmap,
        .set = set,
    };
}

pub fn init(io: Io, arena: *Arena, config: Config) !Network {
    const peers = try collectPeers(config.peers, arena.allocator());

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
    };
}

/// Starts the Network workers. Blocking. May be cancelled as required.
pub fn start(self: *Network) void {
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

fn handleConnectionRw(self: *Network, rdr: *Io.Reader, writer: *Io.Writer) void {
    _ = self; // autofix
    _ = rdr; // autofix
    log.err("TODO!", .{});
    _ = writer.write("NOT YET IMPLEMENTED") catch {};
    writer.flush() catch {};
}

fn handleConnection(self: *Network, stream: Io.net.Stream) void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = stream.reader(self.io, &read_buf);
    var sock_writer = stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    var future = self.io.concurrent(handleConnectionRw, .{ self, rdr, writer }) catch unreachable;
    _ = future.await(self.io);

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
    /// NaCl Box public key. Should be 32 bytes in length.
    pubkey: []const u8,

    /// A nickname for the remote peer.
    nickname: []const u8,

    fixed: bool = false,

    pub fn fix(self: *Peer) !void {
        if (self.fixed) return;
        b64.Decoder.calcSizeUpperBound(self.pubkey);

        self.fixed = true;
    }
};
