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

//! Database access layer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sqlite = @import("sqlite");
const Text = sqlite.Text;

pub const models = @import("models.zig");
const Network = @import("Network.zig");
const util = @import("util.zig");

const log = std.log.scoped(.Repo);

const Repo = @This();

db: sqlite.Database,

pub fn init(data_dir: []const u8, alloc: Allocator) !Repo {
    const db_path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}/zclip.db",
        .{data_dir},
        0,
    );
    defer alloc.free(db_path);

    const db = try sqlite.Database.open(.{
        .path = db_path,
    });

    try initSchema(db);

    return .{ .db = db };
}

fn initSchema(db: sqlite.Database) !void {
    try db.exec(
        \\ CREATE TABLE IF NOT EXISTS peers (
        \\ id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        \\ nickname VARCHAR NOT NULL,
        \\ addr VARCHAR,
        \\ pubkey VARCHAR NOT NULL);
    , .{});

    try db.exec(
        \\ CREATE UNIQUE INDEX IF NOT EXISTS peers_pubkey_idx ON peers (pubkey);
    , .{});

    var self = Repo{ .db = db };
    const version = try self.getSchemaVersion();

    if (version < 1) {
        std.debug.assert(version == 0);

        try db.exec("ALTER TABLE peers ADD COLUMN degraded_reason VARCHAR DEFAULT NULL;", .{});
        try self.incrementSchemaVersion(version);
    }
}

pub fn deinit(repo: *Repo) void {
    repo.db.close();
}

/// Adds a peer and returns their ID.
pub fn addPeer(
    repo: *Repo,
    peer: struct { nickname: []const u8, addr: ?[]const u8, pubkey: []const u8 },
    force: bool,
) !u64 {
    const sql = if (force)
        \\INSERT INTO peers (nickname, addr, pubkey) VALUES (:nickname, :addr, :pubkey) RETURNING id
        \\ON CONFLICT (pubkey) DO UPDATE SET nickname = excluded.nickname, addr = excluded.addr;
    else
        \\INSERT INTO peers (nickname, addr, pubkey) VALUES (:nickname, :addr, :pubkey) RETURNING id;
    ;

    const stmt = try repo.db.prepare(
        struct { nickname: Text, addr: ?Text, pubkey: Text },
        struct { id: u64 },
        sql,
    );
    defer stmt.finalize();
    defer stmt.reset();

    try stmt.bind(.{
        .addr = if (peer.addr) |addr| .{ .data = addr } else null,
        .nickname = .{ .data = peer.nickname },
        .pubkey = .{ .data = peer.pubkey },
    });

    // This won't be null.
    const maybe_id = stmt.step() catch |err| switch (err) {
        error.SQLITE_CONSTRAINT => return error.PeerExists,
        else => return err,
    };

    return maybe_id.?.id;
}

/// Sets a reason as to why a peer is degraded in status. i.e. We refuse to
/// connect to them.
pub fn updatePeerDegraded(repo: *Repo, id: u64, reason: ?Network.Peer.DegradationReason) !void {
    const stmt = try repo.db.prepare(
        struct { reason: ?Text, id: u64 },
        struct { id: u64 },
        "UPDATE peers SET degraded_reason = :reason WHERE id = :id RETURNING id;",
    );
    defer stmt.finalize();
    defer stmt.reset();

    try stmt.bind(.{
        .id = id,
        .reason = if (reason) |r| .{ .data = @tagName(r) } else null,
    });

    const res = try stmt.step();
    if (res == null) return error.NotFound;
}

/// Sets the hostname of a peer by `id`. Errors if the peer does not exist.
pub fn setPeerHostname(repo: *Repo, id: u64, hostname: ?[]const u8) !void {
    const stmt = try repo.db.prepare(
        struct { hostname: ?Text, id: u64 },
        struct { id: u64 },
        "UPDATE peers SET addr = :hostname WHERE id = :id RETURNING id;",
    );
    defer stmt.finalize();
    defer stmt.reset();

    try stmt.bind(.{
        .id = id,
        .hostname = if (hostname) |h| .{ .data = h } else null,
    });

    const res = try stmt.step();
    if (res == null) return error.NotFound;
}

/// Sets the public key of a peer by `id`. Errors if the peer does not exist.
pub fn setPeerPubkey(repo: *Repo, id: u64, pubkey: []const u8) !void {
    const stmt = try repo.db.prepare(
        struct { pubkey: Text, id: u64 },
        struct { id: u64 },
        "UPDATE peers SET pubkey = :pubkey WHERE id = :id RETURNING id;",
    );
    defer stmt.finalize();
    defer stmt.reset();

    try stmt.bind(.{
        .id = id,
        .pubkey = .{ .data = pubkey },
    });

    const res = try stmt.step();
    if (res == null) return error.NotFound;
}

/// Sets the nickname of a peer by `id`. Errors if the peer does not exist.
pub fn setPeerNickname(repo: *Repo, id: u64, nickname: []const u8) !void {
    const stmt = try repo.db.prepare(
        struct { nickname: Text, id: u64 },
        struct { id: u64 },
        "UPDATE peers SET nickname = :nickname WHERE id = :id RETURNING id;",
    );
    defer stmt.finalize();
    defer stmt.reset();

    try stmt.bind(.{
        .id = id,
        .nickname = .{ .data = nickname },
    });

    const res = try stmt.step();
    if (res == null) return error.NotFound;
}

/// Returns the schema version of the DB for migrations.
fn getSchemaVersion(repo: *Repo) !u64 {
    const stmt = try repo.db.prepare(
        struct {},
        struct { user_version: u64 },
        "PRAGMA user_version;",
    );
    defer stmt.finalize();
    defer stmt.reset();

    try stmt.bind(.{});

    const version = try stmt.step();

    return version.?.user_version;
}

/// Bumps the schema version.
fn incrementSchemaVersion(repo: *Repo, current_version: u64) !void {
    // More than healthy room and I like a good power of two.
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.print("PRAGMA user_version = {d};", .{current_version + 1});
    const sql = writer.buffered();

    try repo.db.exec(sql, .{});
}

/// Removes a peer by ID. Returns `error.NotFound` if no such peer exists.
pub fn removePeer(repo: *Repo, id: u64) !void {
    const stmt = try repo.db.prepare(
        struct { id: u64 },
        struct { id: u64 },
        "DELETE FROM peers WHERE id = :id RETURNING id;",
    );
    defer stmt.finalize();
    defer stmt.reset();

    try stmt.bind(.{ .id = id });

    const removed = try stmt.step();
    if (removed == null) return error.NotFound;
}

/// Returns true if the peer exists in DB.
///
/// See `peerExistsByPubkey` for a similar version using the public key.
pub fn peerExistsById(repo: *Repo, id: u64) !bool {
    const select = try repo.db.prepare(
        struct { id: u64 },
        struct { count: u64 },
        "SELECT COUNT(1) AS count FROM peers WHERE id = :id;",
    );
    defer select.finalize();

    defer select.reset();

    try select.bind(.{ .id = id });
    const res = try select.step() orelse unreachable;

    return (res.count == 1);
}

/// Returns true if the peer exists in DB.
///
/// See `peerExistsById` for a similar version using the ID.
pub fn peerExistsByPubkey(repo: *Repo, pubkey: []const u8) !bool {
    const select = try repo.db.prepare(
        struct { pubkey: Text },
        struct { count: u64 },
        "SELECT COUNT(1) AS count FROM peers WHERE pubkey = :pubkey;",
    );
    defer select.finalize();

    defer select.reset();

    try select.bind(.{ .pubkey = pubkey });
    const res = try select.step() orelse unreachable;

    return (res.count == 1);
}

/// The allocator could be an arena to avoid faffing about with cleanup.
///
/// See `peerExistsById` for a version that returns true if present in DB.
pub fn getPeerById(repo: *Repo, id: u64, alloc: Allocator) !Network.Peer {
    const select = try repo.db.prepare(
        struct { id: u64 },
        models.NetworkPeer,
        "SELECT * FROM peers WHERE id = :id;",
    );
    defer select.finalize();

    defer select.reset();

    try select.bind(.{ .id = id });
    const peer = try select.step() orelse return error.NotFound;

    const net_peer = try toNetworkPeer(peer, alloc);

    return net_peer;
}

pub fn getPeerByPubkey(repo: *Repo, pubkey: []const u8, alloc: Allocator) !Network.Peer {
    const select = try repo.db.prepare(
        struct { pubkey: sqlite.Text },
        models.NetworkPeer,
        "SELECT * FROM peers WHERE pubkey = :pubkey;",
    );
    defer select.finalize();

    defer select.reset();

    try select.bind(.{ .pubkey = .{ .data = pubkey } });
    const peer = try select.step() orelse return error.NotFound;

    const net_peer = try toNetworkPeer(peer, alloc);

    return net_peer;
}

fn getPeersSql(repo: *Repo, alloc: Allocator, sql: []const u8) ![]const Network.Peer {
    const select = try repo.db.prepare(
        struct {},
        models.NetworkPeer,
        sql,
    );
    defer select.finalize();

    defer select.reset();

    var out = std.ArrayList(Network.Peer).empty;

    try select.bind(.{});

    while (try select.step()) |peer| {
        try out.append(alloc, try toNetworkPeer(peer, alloc));
    }

    return try out.toOwnedSlice(alloc);
}

/// Caller should free returned slice once done with it using alloc.
///
/// Use an arena to avoid needing to free all slices in each Network peer.
pub fn getPeersNonDegraded(repo: *Repo, alloc: Allocator) ![]const Network.Peer {
    return repo.getPeersSql(
        alloc,
        "SELECT * FROM peers WHERE degraded_reason IS NOT NULL;",
    );
}

/// Caller should free returned slice once done with it using alloc.
///
/// Use an arena to avoid needing to free all slices in each Network peer.
pub fn getPeers(repo: *Repo, alloc: Allocator) ![]const Network.Peer {
    return repo.getPeersSql(
        alloc,
        "SELECT * FROM peers;",
    );
}

/// Callers should probably use an arena or manually free all returned slices
/// when done.
fn toNetworkPeer(peer: models.NetworkPeer, alloc: Allocator) !Network.Peer {
    const pubkey = try util.base64decode(peer.pubkey.data, alloc);
    defer alloc.free(pubkey);

    var host: ?Network.Host = null;
    if (peer.addr) |addr| {
        host = try Network.Host.parse(addr.data);
    }

    const duped_nickname = try alloc.dupe(u8, peer.nickname.data);
    errdefer alloc.free(duped_nickname);

    std.debug.assert(pubkey.len == 32);

    return .{
        .host = host,
        .nickname = duped_nickname,
        .id = peer.id,
        .pubkey = pubkey[0..32].*,
        .degradation = if (peer.degraded_reason) |r|
            toDegradationReason(r.data, peer.id)
        else
            null,
    };
}

/// If unrecognised but still set in the DB for some reason, we just return
/// `.remote_rejected` and log something.
fn toDegradationReason(reason: ?[]const u8, id: u64) ?Network.Peer.DegradationReason {
    if (reason == null) return null;

    // If this trips, this function needs an update.
    comptime {
        std.debug.assert(
            @typeInfo(Network.Peer.DegradationReason).@"enum".field_names.len == 3,
        );
    }

    if (std.mem.eql(u8, reason.?, "unrecognised_pubkey")) return .unrecognised_pubkey;
    if (std.mem.eql(u8, reason.?, "remote_missing_our_pubkey")) return .remote_missing_our_pubkey;
    if (std.mem.eql(u8, reason.?, "remote_rejected")) return .remote_rejected;

    log.warn("Unrecognised degradation reason in DB for peer ID {d}. Returning .remote_rejected for now.", .{id});

    return .remote_rejected;
}
