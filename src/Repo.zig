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

pub fn getPeerById(repo: *Repo, id: u64) !Network.Peer {
    const select = try repo.db.prepare(
        struct { id: u64 },
        models.NetworkPeer,
        "SELECT * FROM peers WHERE id = :id;",
    );
    defer select.finalize();

    defer select.reset();

    try select.bind(.{ .id = id });
    const peer = try select.step() orelse return error.NotFound;

    const net_peer = try toNetworkPeer(peer, repo.alloc);

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
pub fn getPeersNonDegraded(repo: *Repo, alloc: Allocator) ![]const Network.Peer {
    return repo.getPeersSql(
        alloc,
        "SELECT * FROM peers WHERE degraded_reason IS NOT NULL;",
    );
}

/// Caller should free returned slice once done with it using alloc.
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
    };
}
