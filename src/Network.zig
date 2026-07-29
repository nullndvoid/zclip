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
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

const Serde = @import("serde");

const AppConfig = @import("Config.zig");
pub const Identity = @import("network/Identity.zig");
const NoiseSession = @import("network/NoiseSession.zig");
const Packet = @import("network/Packet.zig");
const Repo = @import("Repo.zig");
const util = @import("util.zig");

const log = std.log.scoped(.net);

io: Io,
alloc: Allocator,
server: Io.net.Server,
tasks: Io.Group,
/// The list of peers this machine should attempt to connect to first.
connectable: []const Peer,
/// This daemon's identity.
identity: Identity,
/// The database connection.
repo: *Repo,
shutdown: Io.Event = .unset,
/// Events are sent from the Unix socket handler when new peers are committed
/// to DB.
peer_added: *Io.Queue(Peer),

const Network = @This();

pub const DEFAULT_NET_PORT = 48500;

pub const Config = struct {
    bind_addr: Io.net.IpAddress = .{ .ip4 = .unspecified(DEFAULT_NET_PORT) },
    peers: []Peer = &.{},
};

pub const Host = struct {
    name_buf: [Io.net.HostName.max_len]u8 = @splat(0),
    name_len: u8 = 0,
    port: u16,

    /// Parses an IP or hostname and optional port number from a string.
    pub fn parse(str: []const u8) !Host {
        const colon = std.mem.indexOfScalar(u8, str, ':');
        var rest = str;
        const port = blk: {
            if (colon) |idx| {
                if (idx == str.len - 1) return error.InvalidPort;
                rest = str[0..idx];
                break :blk try std.fmt.parseInt(u16, str[idx + 1 ..], 10);
            } else {
                break :blk DEFAULT_NET_PORT;
            }
        };

        try Io.net.HostName.validate(rest);

        var self = Host{
            .name_len = @intCast(rest.len),
            .port = port,
        };
        @memcpy(self.name_buf[0..rest.len], rest);

        return self;
    }

    pub fn hostname(self: *const Host) Io.net.HostName {
        return .{ .bytes = self.name_buf[0..self.name_len] };
    }

    pub fn format(
        self: Host,
        writer: *std.Io.Writer,
    ) Io.Writer.Error!void {
        try writer.print("{s}:{d}", .{ self.name_buf[0..self.name_len], self.port });
    }
};

/// Parses an IP from a string, setting the port to default if not given.
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
        if (p.host != null and std.mem.order(u8, &ident.public_key, &p.pubkey) == .gt)
            try out.append(alloc, p);
    }

    return try out.toOwnedSlice(alloc);
}

pub fn init(io: Io, alloc: Allocator, identity: Identity, repo: *Repo, peer_added: *Io.Queue(Peer), config: Config) !Network {
    const connectable = try getConnectable(identity, config.peers, alloc);
    errdefer alloc.free(connectable);

    log.debug("Starting listener on {f}", .{config.bind_addr});

    const server = try config.bind_addr.listen(io, .{
        .reuse_address = true,
    });

    return .{
        .io = io,
        .alloc = alloc,
        .server = server,
        .tasks = .init,
        .connectable = connectable,
        .identity = identity,
        .repo = repo,
        .peer_added = peer_added,
    };
}

fn waitForShutdown(self: *Network) Io.Cancelable!void {
    try self.shutdown.wait(self.io);
}

const Backoff = struct {
    const delays_s = [_]i64{ 1, 3, 5, 10, 20, 30 };

    failed: bool = false,
    delay_idx: usize = 0,
    attempts: usize = 1,

    /// Sleeps for the current delay, then advances to the next one.
    /// Returns `error.ShuttingDown` if `shutdown` is set while sleeping.
    fn wait(self: *Backoff, io: Io, shutdown: *Io.Event) error{ Canceled, ShuttingDown }!void {
        shutdown.waitTimeout(io, .{ .duration = .{
            .raw = .fromSeconds(delays_s[self.delay_idx]),
            .clock = .real,
        } }) catch |err| switch (err) {
            error.Timeout => {
                if (self.delay_idx != delays_s.len - 1)
                    self.delay_idx += 1;

                self.attempts += 1;
                return;
            },
            error.Canceled => return error.Canceled,
        };

        return error.ShuttingDown;
    }

    /// Jumps straight to the maximum delay.
    fn saturate(self: *Backoff) void {
        self.delay_idx = delays_s.len - 1;
    }

    fn maxDelaySeconds() i64 {
        return delays_s[delays_s.len - 1];
    }
};

fn connectWithBackoff(self: *Network, host: Host, peer: Peer, backoff: *Backoff) error{ Canceled, ShuttingDown }!Io.net.Stream {
    while (true) {
        return host.hostname().connect(
            self.io,
            host.port,
            .{ .mode = .stream, .protocol = .tcp },
        ) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                if (!backoff.failed) {
                    backoff.failed = true;
                    log.warn("Cannot reach `{s}`. Retrying...", .{peer.nickname});
                } else {
                    log.debug("Cannot reach `{s}`. Attempt {d}. Retrying...", .{ peer.nickname, backoff.attempts });
                }

                try backoff.wait(self.io, &self.shutdown);
                continue;
            },
        };
    }
}

/// Attempts to connect to a peer, retrying with backoff, then services the
/// connection until it closes. Only fails on cancellation; anything fatal for
/// this one peer is logged and starts retrying in case they reconnect.
fn connectToPeer(self: *Network, peer: Peer) error{Canceled}!void {
    var backoff = Backoff{};

    while (true) {
        const stream = self.connectWithBackoff(peer.host.?, peer, &backoff) catch |err| switch (err) {
            error.ShuttingDown => return,
            error.Canceled => return error.Canceled,
        };
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
            peer.pubkey,
            .{},
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
                backoff.wait(self.io, &self.shutdown) catch |wait_err| switch (wait_err) {
                    error.ShuttingDown => return,
                    error.Canceled => return error.Canceled,
                };
                continue;
            },
            else => {
                log.err("Noise handshake with peer `{s}` failed: {t}. Closing the connection and retrying.", .{ peer.nickname, err });
                stream.close(self.io);

                backoff.wait(self.io, &self.shutdown) catch |wait_err| switch (wait_err) {
                    error.ShuttingDown => return,
                    error.Canceled => return error.Canceled,
                };
                continue;
            },
        };

        defer session.deinit();
        defer stream.close(self.io);

        self.processPackets(rdr, writer, &session, peer) catch |err| switch (err) {
            error.Canceled => {},
            else => {
                log.err("Processing packets failed. Reason: {t}. Retrying.", .{err});

                backoff.wait(self.io, &self.shutdown) catch |wait_err| switch (wait_err) {
                    error.ShuttingDown => return,
                    error.Canceled => return error.Canceled,
                };
                continue;
            },
        };

        if (self.shutdown.isSet()) return;

        backoff = Backoff{};
        continue;
    }
}

/// Starts the Network workers. Blocking. May be cancelled as required.
pub fn start(self: *Network) !void {
    if (self.connectable.len >= 1) {
        log.debug("Sending outbound connection requests to {d} peers", .{self.connectable.len});
    }

    for (self.connectable) |connectable| {
        self.tasks.concurrent(self.io, connectToPeer, .{ self, connectable }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => log.err(
                "No concurrency available to dial peer `{s}`. Skipping them.",
                .{connectable.nickname},
            ),
        };
    }

    log.debug("Started accepting connections", .{});
    try self.acceptAndMakeConns();
    log.debug("No longer accepting connections", .{});
}

/// Stop the accept loop (by cancelling `start`) before calling this, so no
/// new connection tasks are spawned into the group while it is awaited.
pub fn stop(self: *Network) void {
    self.shutdown.set(self.io);
    self.tasks.await(self.io) catch {};
}

pub fn deinit(self: *Network) void {
    self.tasks.cancel(self.io);
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
        .{},
    ) catch |err| switch (err) {
        error.PeerDoesNotHoldPubkey => return,
        else => {
            log.err("Something went wrong with the Noise handshake :(. What: {t}", .{err});
            log.err("The connection will be closed.", .{});

            return;
        },
    };

    defer session.deinit();

    // Check the peer is in DB.
    const peer = self.repo.getPeerByPubkey(&session.peer_pubkey, conn_arena.allocator()) catch |err| {
        switch (err) {
            error.NotFound => {
                log.warn("Peer with pubkey {b64} was not found! Unknown connection.", .{&session.peer_pubkey});
            },
            else => {
                log.err("Something went wrong looking for peer with pubkey {b64} in DB! What: {t}.", .{ &session.peer_pubkey, err });
            },
        }

        return err;
    };

    try self.processPackets(rdr, writer, &session, peer);
}

fn processPackets(self: *Network, rdr: *Io.Reader, socket_writer: *Io.Writer, session: *NoiseSession, peer: Peer) !void {
    log.debug(
        "Encrypted connection established with peer #{d} ({s})",
        .{ peer.id, peer.nickname },
    );

    var encrypted_writer = session.encryptedWriter(socket_writer);
    const writer = &encrypted_writer.interface;

    const Task = union(enum) { read: anyerror!void, shutdown: Io.Cancelable!void };
    var buf: [2]Task = undefined;
    var select = Io.Select(Task).init(self.io, &buf);
    defer select.cancelDiscard();

    try select.concurrent(.shutdown, waitForShutdown, .{self});
    try select.concurrent(
        .read,
        packetReadLoop,
        .{ rdr, writer, session, peer },
    );

    switch (try select.await()) {
        .read => |result| try result,
        .shutdown => {
            select.cancelDiscard();

            const packet = Packet.init(self.io, 0, .shutting_down);
            sendGoodbye(packet, writer) catch |err| {
                log.debug("Could not send shutdown packet to peer #{d} ({s}): {t}", .{ peer.id, peer.nickname, err });
            };
        },
    }
}

fn sendGoodbye(packet: Packet, writer: *Io.Writer) !void {
    try packet.encode(writer);
    try writer.flush();
}

/// `writer` already handles encryption, you need only pass this to
/// `Packet.encode` and flush.
fn packetReadLoop(rdr: *Io.Reader, writer: *Io.Writer, session: *NoiseSession, peer: Peer) anyerror!void {
    _ = writer; // Used once payload types that warrant replies are handled.

    while (true) {
        const bytes = session.recv(rdr) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        const packet = try Packet.decode(bytes);

        log.debug("Peer #{d} sent packet\n{f}", .{ peer.id, packet });

        switch (packet.payload) {
            .shutting_down => {
                log.info("Peer #{d} ({s}) is shutting down. Terminating connection!", .{ peer.id, peer.nickname });
                return;
            },

            // TODO: Handle the remaining payload types.
            else => log.warn(
                "Peer #{d} ({s}) sent an unhandled `{t}` packet. Ignoring it.",
                .{ peer.id, peer.nickname, std.meta.activeTag(packet.payload) },
            ),
        }
    }
}

fn handleConnection(self: *Network, stream: Io.net.Stream) void {
    defer stream.close(self.io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var sock_rdr = stream.reader(self.io, &read_buf);
    var sock_writer = stream.writer(self.io, &write_buf);

    const rdr = &sock_rdr.interface;
    const writer = &sock_writer.interface;

    self.handleConnectionRw(rdr, writer) catch |err| {
        switch (err) {
            error.Canceled => return,
            else => {},
        }

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

fn acceptAndMakeConns(self: *Network) !void {
    const SelectTask = union(enum) {
        accept: void,
        make_conns: Io.Cancelable!void,
    };
    var select_buf: [2]SelectTask = undefined;
    var select = Io.Select(SelectTask).init(self.io, &select_buf);

    try select.concurrent(.accept, acceptConnections, .{self});
    try select.concurrent(.make_conns, makeNewConns, .{self});
    defer select.cancelDiscard();

    switch (try select.await()) {
        .make_conns => |ret| try ret,
        else => {},
    }
}

fn makeNewConns(self: *Network) Io.Cancelable!void {
    while (true) {
        const peer = self.peer_added.getOne(self.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // This is unreachable because the daemon does not close the queue
            // until it exits.
            error.Closed => unreachable,
        };

        log.debug("New peer added: {f}", .{peer});

        if (std.mem.order(u8, &self.identity.public_key, &peer.pubkey) != .gt) continue;

        if (peer.host) |_| {
            // Again, if this fails, maybe warnlog. The user might just need
            // to restart their daemon.
            self.tasks.concurrent(
                self.io,
                connectToPeer,
                .{ self, peer },
            ) catch continue;
        } else {
            log.warn("This is a bug! You are missing a host, but the other peer will not connect!\n\nPeer: {f}", .{peer});
        }
    }
}

fn acceptConnections(self: *Network) void {
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

        self.tasks.concurrent(self.io, handleConnection, .{ self, stream }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => stream.close(self.io),
        };
    }
}

/// Used internally.
pub const Peer = struct {
    /// Peers public key. This is decoded from Base64.
    pubkey: [32]u8,

    /// A nickname for the remote peer.
    nickname: []const u8,

    /// The IP address or hostname of the remote peer.
    /// Null if the remote should only connect to this one.
    host: ?Host,

    /// A (locally) unique ID for the peer.
    /// Globally unique IDs could be generated using a hash of one's own public
    /// key.
    id: u64 = 0,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{d} ", .{self.id});
        try writer.print("{s}", .{self.nickname});
        if (self.host) |host| try writer.print(" {f}", .{host});
    }
};
