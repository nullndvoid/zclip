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

pub const Identity = @import("network/Identity.zig");
const NoiseSession = @import("network/NoiseSession.zig");
const Packet = @import("network/Packet.zig");
const PeerRecheckPayload = @import("UnixSocket.zig").EditPeerPayload;
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
/// Commands are sent from the Unix socket handler.
///
/// Owned by Daemon so no need to close.
commands: *Io.Queue(Command),
/// Guards the hashmap of active connections.
active_conns_lock: Io.RwLock,
/// Mapping between peer IDs and a per-connection "please stop" signal.
active_conns: std.AutoHashMap(u64, *Io.Event),

const Network = @This();

pub const DEFAULT_NET_PORT = 48500;

pub const Config = struct {
    bind_addr: Io.net.IpAddress = .{ .ip4 = .unspecified(DEFAULT_NET_PORT) },
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

pub fn init(io: Io, alloc: Allocator, identity: Identity, repo: *Repo, peers: []const Peer, commands: *Io.Queue(Command), config: Config) !Network {
    const connectable = try getConnectable(identity, peers, alloc);
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
        .commands = commands,
        .active_conns = .init(alloc),
        .active_conns_lock = .init,
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
                    log.warn("Peer `{s}` does not have this machines public key. Copy the following line to update your peers config. Will retry every {d}s", .{ peer.nickname, Backoff.maxDelaySeconds() });
                    const b64_pk = util.encodeKey(self.identity.public_key);
                    log.info("zclip peer edit --id ID -k \"{s}\"", .{b64_pk});
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

        var encrypted_writer = session.encryptedWriter(writer);
        const encwriter = &encrypted_writer.interface;
        self.processPackets(rdr, encwriter, &session, peer, conn_arena.allocator()) catch |err| switch (err) {
            error.Canceled => {},
            error.PeerRemovedLocally, error.PeerDegraded => {
                log.info("Will not retry peer `{s}`.", .{peer.nickname});
                return;
            },
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
pub fn stop(self: *Network) !void {
    self.shutdown.set(self.io);
    try self.tasks.await(self.io);
}

pub fn deinit(self: *Network) void {
    self.tasks.cancel(self.io);
    self.server.deinit(self.io);
    self.alloc.free(self.connectable);
    self.active_conns.deinit();
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

    var encrypted_writer = session.encryptedWriter(writer);
    const encwriter = &encrypted_writer.interface;

    const encoded = util.encodeKey(session.peer_pubkey);

    // Check the peer is in DB.
    const peer = self.repo.getPeerByPubkey(&encoded, conn_arena.allocator()) catch |err| {
        switch (err) {
            error.NotFound => {
                log.warn("Peer with pubkey {s} was not found! Unknown connection.", .{&encoded});

                const packet = Packet.init(
                    self.io,
                    0,
                    .{ .err = .{ .tag = .PeerRemoved } },
                );

                try packet.encode(encwriter);
                try encwriter.flush();
            },
            else => {
                log.err("Something went wrong looking for peer with pubkey {s} in DB! What: {t}.", .{ &encoded, err });
            },
        }

        return err;
    };

    try self.processPackets(
        rdr,
        encwriter,
        &session,
        peer,
        conn_arena.allocator(),
    );
}

fn processPackets(
    self: *Network,
    rdr: *Io.Reader,
    writer: *Io.Writer,
    session: *NoiseSession,
    peer: Peer,
    alloc: Allocator,
) anyerror!void {
    var removed: Io.Event = .unset;

    try self.registerConn(peer.id, &removed);
    defer self.unregisterConn(peer.id);

    log.debug(
        "Encrypted connection established with peer #{d} ({s})",
        .{ peer.id, peer.nickname },
    );

    const Task = union(enum) { read: anyerror!void, shutdown: Io.Cancelable!void, removed: Io.Cancelable!void };
    var buf: [3]Task = undefined;
    var select = Io.Select(Task).init(self.io, &buf);
    defer select.cancelDiscard();

    try select.concurrent(.shutdown, waitForShutdown, .{self});
    try select.concurrent(.removed, waitForRemoval, .{ &removed, self.io });
    try select.concurrent(
        .read,
        packetReadLoop,
        .{ self, rdr, writer, session, peer, alloc },
    );

    switch (try select.await()) {
        .read => |result| try result,
        .shutdown => {
            select.cancelDiscard();

            sendGoodbye(self.io, writer) catch |err| {
                log.debug("Could not send shutdown packet to peer #{d} ({s}): {t}", .{ peer.id, peer.nickname, err });
            };
        },
        .removed => {
            select.cancelDiscard();

            log.info("Peer #{d} ({s}) was removed locally. Closing the connection.", .{ peer.id, peer.nickname });

            return error.PeerRemovedLocally;
        },
    }
}

fn waitForRemoval(removed: *Io.Event, io: Io) Io.Cancelable!void {
    try removed.wait(io);
}

fn sendGoodbye(io: Io, writer: *Io.Writer) !void {
    const packet = Packet.init(io, 0, .shutting_down);

    try packet.encode(writer);
    try writer.flush();
}

/// `writer` already handles encryption, you need only pass this to
/// `Packet.encode` and flush.
fn packetReadLoop(
    self: *Network,
    rdr: *Io.Reader,
    writer: *Io.Writer,
    session: *NoiseSession,
    peer: Peer,
    alloc: Allocator,
) anyerror!void {
    _ = writer; // Used once payload types that warrant replies are handled.

    while (true) {
        const bytes = try session.recv(rdr);

        const packet = try Packet.decode(bytes, alloc);
        // Failure to do this could be a memory leak since this `alloc` is
        // backed by a long-lived arena.
        defer packet.deinit(alloc);

        log.debug("Peer #{d} sent packet\n{f}", .{ peer.id, packet });

        switch (packet.payload) {
            .shutting_down => {
                log.info("Peer #{d} ({s}) is shutting down. Terminating connection!", .{ peer.id, peer.nickname });
                return;
            },
            .err => |e| switch (e.tag) {
                .PeerRemoved => {
                    log.warn("Peer #{d} ({s}) asked us to stop connecting. Marking degraded.", .{ peer.id, peer.nickname });

                    self.repo.updatePeerDegraded(peer.id, .remote_rejected) catch |db_err| {
                        log.err("Failed to mark peer #{d} as degraded: {t}", .{ peer.id, db_err });
                    };

                    return error.PeerDegraded;
                },
                else => log.warn(
                    "Peer #{d} ({s}) sent an unhandled error `{t}`. Ignoring it.",
                    .{ peer.id, peer.nickname, e.tag },
                ),
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

fn registerConn(self: *Network, peer_id: u64, removed: *Io.Event) !void {
    try self.active_conns_lock.lock(self.io);
    defer self.active_conns_lock.unlock(self.io);
    try self.active_conns.put(peer_id, removed);
}

fn unregisterConn(self: *Network, peer_id: u64) void {
    self.active_conns_lock.lockUncancelable(self.io);
    defer self.active_conns_lock.unlock(self.io);
    _ = self.active_conns.remove(peer_id);
}

fn acceptAndMakeConns(self: *Network) !void {
    const SelectTask = union(enum) {
        accept: void,
        make_conns: Io.Cancelable!void,
    };
    var select_buf: [2]SelectTask = undefined;
    var select = Io.Select(SelectTask).init(self.io, &select_buf);

    try select.concurrent(.accept, acceptConnections, .{self});
    try select.concurrent(.make_conns, processCommands, .{self});
    defer select.cancelDiscard();

    switch (try select.await()) {
        .make_conns => |ret| try ret,
        else => {},
    }
}

fn processCommands(self: *Network) Io.Cancelable!void {
    while (true) {
        const cmd = self.commands.getOne(self.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // This is unreachable because the daemon does not close the queue
            // until it exits.
            error.Closed => unreachable,
        };

        switch (cmd) {
            .peer_add => |peer| self.handlePeerAdd(peer),
            .peer_rm => |id| self.handlePeerRm(id),
            .peer_recheck => |payload| self.handlePeerRecheck(payload),
        }
    }
}

/// Takes the 'diff' of an edited peer.
///
/// If anything of note was changed, the connection should be dropped and
/// re-established.
fn handlePeerRecheck(self: *Network, payload: PeerRecheckPayload) void {
    const peer = self.repo.getPeerById(payload.id, self.alloc) catch |e| {
        log.err("Could not handle recheck for peer with ID {d}. Failed to fetch peer from DB. Why: {t}", .{ payload.id, e });
        log.info("Hint: Restarting the daemon could fix this issue.", .{});

        return;
    };
    defer self.alloc.free(peer.nickname);

    log.info("Peer recheck triggered for {s}.", .{peer.nickname});

    // Attempt to connect now if no longer marked degraded.
    if (payload.params.clear_degraded and peer.host != null) {
        return self.connectToPeerIfApplicable(peer);
    }

    if (payload.params.clear_host) {
        log.warn("Cleared hostname for peer {s}. This will not apply until you restart the daemon.", .{peer.nickname});
    }

    // Drop current connection and reconnect using new public key or hostname.
    if (payload.params.pubkey != null or
        payload.params.host != null)
    {
        self.active_conns_lock.lock(self.io) catch {
            log.warn("Could not drop current connection for peer {s}. You should restart the daemon.", .{peer.nickname});
        };
        const removed = self.active_conns.fetchRemove(payload.id);
        self.active_conns_lock.unlock(self.io);

        if (removed) |kv| {
            kv.value.set(self.io);

            log.info("Dropping old connection for peer {s}", .{peer.nickname});
        }

        // Now just attempt to reconnect.
        return self.connectToPeerIfApplicable(peer);
    }

    log.info("Recheck: nothing to be done for peer {s}.", .{peer.nickname});
}

fn handlePeerRm(self: *Network, id: u64) void {
    self.active_conns_lock.lock(self.io) catch return;
    const removed = self.active_conns.fetchRemove(id);

    // Unlock right away because on cleanup, connections will deregister
    // themselves. We don't want to deadlock!
    self.active_conns_lock.unlock(self.io);

    if (removed) |kv| {
        kv.value.set(self.io);

        log.debug("Signalled removal to in-flight connection with peer #{d}", .{id});
    }
}

fn connectToPeerIfApplicable(self: *Network, peer: Peer) void {
    // TODO: Enforce this throughout e.g. on edit/add etc.
    std.debug.assert(std.mem.order(u8, &self.identity.public_key, &peer.pubkey) != .eq);

    if (std.mem.order(u8, &self.identity.public_key, &peer.pubkey) != .gt) return;

    log.info("Connecting to peer {s}", .{peer.nickname});

    if (peer.host) |_| {
        self.tasks.concurrent(
            self.io,
            connectToPeer,
            .{ self, peer },
        ) catch {
            log.err(
                "Could not connect to ({s} (id {d})). Consider restarting the daemon.",
                .{ peer.nickname, peer.id },
            );
            return;
        };
    } else {
        log.warn("This is a bug! You are missing a host, but the other peer will not connect!\n\nPeer: {f}", .{peer});
    }
}

fn handlePeerAdd(self: *Network, peer: Peer) void {
    log.debug("New peer added: {f}", .{peer});

    self.connectToPeerIfApplicable(peer);
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

pub const Command = union(enum) {
    /// A `Peer` was added to the DB.
    peer_add: Peer,
    /// `Peer` was removed from the DB. This contains it's local ID.
    peer_rm: u64,
    /// `Peer`'s details were edited. If there is a live connection it may need
    /// re-establishing.
    peer_recheck: PeerRecheckPayload,
};

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

    /// Set if the peer is marked as degraded.
    degradation: ?DegradationReason = null,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.nickname});
    }

    /// Dupes any allocated slices. Be sure to call `deinit` when done.
    pub fn clone(self: Peer, alloc: Allocator) Allocator.Error!Peer {
        return .{
            .id = self.id,
            .pubkey = self.pubkey,
            .host = self.host,
            .degradation = self.degradation,
            .nickname = try alloc.dupe(u8, self.nickname),
        };
    }

    /// Frees any allocated slices.
    pub fn deinit(self: Peer, alloc: Allocator) void {
        alloc.free(self.nickname);
    }

    /// Why the Peer is not currently connectable and we are refusing to keep
    /// trying. Good to avoid spamming logs if you misconfigured something.
    pub const DegradationReason = enum(u8) {
        unrecognised_pubkey = 0,
        remote_missing_our_pubkey = 1,
        remote_rejected = 2,
    };

    // This is a reminder that if this trips, you might need to migrate the
    // DB schema.
    comptime {
        std.debug.assert(@typeInfo(DegradationReason).@"enum".field_names.len == 3);
    }
};
