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

//! Sets up Noise sessions between local and remote peer.
//!
//! Uses Noise_IK_25519.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Hasher = std.crypto.hash.sha2.Sha256;

const serde = @import("serde");

const Network = @import("../Network.zig");
const Repo = @import("../Repo.zig");
const util = @import("../util.zig");
const CipherState = @import("CipherState.zig");
const HandshakeState = @import("HandshakeState.zig");

const log = std.log.scoped(.NoiseSession);

const NoiseSession = @This();

/// Encrypted and framed messages are always this large.
pub const MESSAGE_LENGTH = 65535;
pub const AEAD_TAG_LENGTH = 16;
// 16 bytes AEAD tag and u16 prefix for padding gives the biggest possible plaintext.
pub const MAX_PAYLOAD_LENGTH = MESSAGE_LENGTH - AEAD_TAG_LENGTH - 2;

/// Handshake messages are small but size generously.
const HANDSHAKE_BUF_LEN = 256;

io: Io,
alloc: Allocator,
read: CipherState,
write: CipherState,
read_buf: []u8,
write_buf: []u8,
plain_buf: []u8,
/// Stored for debug logging.
peer_nick: []const u8,

/// Makes no attempt to tell peer about this.
pub fn deinit(self: *NoiseSession) void {
    self.read.deinit();
    self.write.deinit();

    std.crypto.secureZero(u8, self.plain_buf);

    self.alloc.free(self.read_buf);
    self.alloc.free(self.write_buf);
    self.alloc.free(self.plain_buf);
}

/// Initiator if `peer_pubkey` is not null.
///
/// All messages are sent padded, prefixed with their actual size.
///
/// * AEAD is AES256-GCM
/// * DH is x25519
/// * Hash function is SHA-256.
pub fn init(
    io: Io,
    alloc: Allocator,
    rdr: *Io.Reader,
    writer: *Io.Writer,
    local_keypair: Network.Identity,
    peer_pubkey: ?[]const u8,
    repo: *Repo,
) !NoiseSession {
    const initiator = peer_pubkey != null;
    const s = HandshakeState.KeyPair{
        .public = local_keypair.public_key,
        .secret = local_keypair.private_key,
    };
    const rs: ?HandshakeState.Key = if (peer_pubkey) |pk| pk[0..32].* else null;

    var handshake = try HandshakeState.init(initiator, &.{}, s, rs);

    const read_buf = try alloc.alloc(u8, MESSAGE_LENGTH);
    errdefer alloc.free(read_buf);

    const write_buf = try alloc.alloc(u8, MESSAGE_LENGTH);
    errdefer alloc.free(write_buf);

    const plain_buf = try alloc.alloc(u8, MAX_PAYLOAD_LENGTH);
    errdefer alloc.free(plain_buf);

    var msg_buf: [HANDSHAKE_BUF_LEN]u8 = undefined;
    var payload_buf: [HANDSHAKE_BUF_LEN]u8 = undefined;

    var peer: ?Network.Peer = null;
    var pubkey_b64: []const u8 = &.{};
    defer if (pubkey_b64.len != 0) alloc.free(pubkey_b64);

    if (initiator) {
        pubkey_b64 = try util.base64encode(peer_pubkey.?, alloc);

        peer = repo.getPeerByPubkey(pubkey_b64, alloc) catch |err| switch (err) {
            error.NotFound => {
                log.warn("Attempted to connect to peer with pubkey {s} but it was not found in the DB!", .{pubkey_b64});
                return error.UnknownPeer;
            },
            else => {
                log.err("Could not check peer in db. Why: {t}", .{err});
                return err;
            },
        };

        // -> e, es, s, ss
        const len0 = try handshake.writeMessage(io, &.{}, &msg_buf);
        try sendFrame(writer, msg_buf[0..len0]);

        // <- e, ee, se
        const m1 = try readFrame(rdr, &msg_buf);
        _ = try handshake.readMessage(m1, &payload_buf);
    } else {
        // <- e, es, s, ss
        const m0 = try readFrame(rdr, &msg_buf);
        _ = handshake.readMessage(m0, &payload_buf) catch |err| switch (err) {
            error.DecryptionFailed => {
                log.warn("Peer does not hold correct public key. Aborting.", .{});
                return error.PeerDoesNotHoldPubkey;
            },
            else => return err,
        };

        std.debug.assert(handshake.rs != null);
        pubkey_b64 = try util.base64encode(&handshake.rs.?, alloc);

        peer = repo.getPeerByPubkey(pubkey_b64, alloc) catch |err| switch (err) {
            error.NotFound => {
                log.warn("Peer tried connecting with unknown pubkey {s}. Aborting.", .{pubkey_b64});
                return error.UnknownPeer;
            },
            else => {
                log.err("Could not check peer in db. Why: {t}", .{err});
                return err;
            },
        };

        // -> e, ee, se
        const l1 = try handshake.writeMessage(io, &.{}, &msg_buf);
        try sendFrame(writer, msg_buf[0..l1]);
    }

    std.debug.assert(peer != null);
    std.debug.assert(handshake.done());

    const split = handshake.split();

    return .{
        .io = io,
        .alloc = alloc,
        .read = if (initiator) split.@"1" else split.@"0",
        .write = if (initiator) split.@"0" else split.@"1",
        .read_buf = read_buf,
        .write_buf = write_buf,
        .plain_buf = plain_buf,
        .peer_nick = peer.?.nickname,
    };
}

fn sendFrame(writer: *Io.Writer, data: []const u8) !void {
    if (data.len > MESSAGE_LENGTH)
        @panic("sendFrame called with too large a message! This is a bug.");

    try writer.writeInt(u16, @intCast(data.len), .big);
    try writer.writeAll(data);
    try writer.flush();
}

fn readFrame(rdr: *Io.Reader, buf: []u8) ![]const u8 {
    const length = try rdr.takeInt(u16, .big);
    if (length > buf.len) return error.FrameTooLarge;

    try rdr.readSliceAll(buf[0..length]);

    return buf[0..length];
}

pub fn send(self: *NoiseSession, writer: *Io.Writer, data: []const u8) !void {
    const bytes = try self.write.encryptWithAdFramed("", data, self.write_buf);
    std.debug.assert(bytes.len == MESSAGE_LENGTH);

    try sendFrame(writer, bytes);
}

/// The returned slice is valid until the next call to recv.
pub fn recv(self: *NoiseSession, rdr: *Io.Reader) ![]const u8 {
    const frame = try readFrame(rdr, self.read_buf);

    const got = try self.read.decryptWithAdFramed("", frame);
    @memcpy(self.plain_buf[0..got.len], got);

    return self.plain_buf[0..got.len];
}

/// Sends some data, messagepack encoded.
pub fn sendT(self: *NoiseSession, writer: *Io.Writer, alloc: Allocator, that: anytype) !void {
    const data = try serde.msgpack.toSlice(alloc, that);
    defer alloc.free(data);
    try self.send(writer, data);
}

/// Receives some data, messagepack encoded. Performs no validation on the received data.
pub fn recvT(self: *NoiseSession, comptime T: type, rdr: *Io.Reader, alloc: Allocator) !T {
    const bytes = try self.recv(rdr);

    return try serde.msgpack.fromSlice(T, alloc, bytes);
}
