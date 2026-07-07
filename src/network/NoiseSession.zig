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

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Hasher = std.crypto.hash.sha2.Sha256;

const noisey = @import("noisey");
const serde = @import("serde");

const Network = @import("../Network.zig");

const log = std.log.scoped(.NoiseSession);

const H = noisey.Hash.Hash(Hasher);

const NoiseSession = @This();

const PATTERN = "Noise_IK_25519_AESGCM_SHA256";
io: Io,
alloc: Allocator,
opts: Opts,
read: noisey.CipherState,
write: noisey.CipherState,
read_buf: []u8,
write_buf: []u8,
plain_buf: []u8,

pub const Opts = struct {
    initiator: bool = true,
};

/// Makes no attempt to tell peer about this.
pub fn deinit(self: *NoiseSession) void {
    if (self.read.k) |*k| {
        std.crypto.secureZero(u8, k);
    }

    if (self.write.k) |*k| {
        std.crypto.secureZero(u8, k);
    }

    std.crypto.secureZero(u8, self.plain_buf);

    self.alloc.free(self.read_buf);
    self.alloc.free(self.write_buf);
    self.alloc.free(self.plain_buf);
}

pub fn init(
    io: Io,
    alloc: Allocator,
    rdr: *Io.Reader,
    writer: *Io.Writer,
    local_keypair: Network.Identity,
    peer_map: *const Network.PeerMap,
    peer_pubkey: ?[]const u8,
    opts: Opts,
) !NoiseSession {
    const read_buf = try alloc.alloc(u8, noisey.MAX_MESSAGE_LENGTH);
    errdefer alloc.free(read_buf);

    const write_buf = try alloc.alloc(u8, noisey.MAX_MESSAGE_LENGTH);
    errdefer alloc.free(write_buf);

    const plain_buf = try alloc.alloc(u8, noisey.MAX_PAYLOAD_LENGTH);
    errdefer alloc.free(plain_buf);

    var aes = noisey.Cipher.Aes256Gcm{};
    const cipher_unpadded = aes.cipher(false);

    var x25519 = noisey.Dh.X25519.init(io, alloc);
    const dh = x25519.interface();

    const kp = noisey.Dh.KeyPair{
        .private = &local_keypair.private_key,
        .public = &local_keypair.public_key,
    };

    var handshake = try noisey.HandshakeState(H).init(
        alloc,
        cipher_unpadded,
        dh,
        noisey.IK,
        PATTERN,
        &.{},
        opts.initiator,
        kp,
        if (opts.initiator) peer_pubkey else null,
    );
    defer handshake.deinit();

    var msg_buf: [256]u8 = undefined;
    var payload_buf: [256]u8 = undefined;

    if (opts.initiator) {
        // e, es, s, ss
        const len0 = try handshake.writeMessage(&.{}, &msg_buf);
        try sendFrame(writer, msg_buf[0..len0]);

        // <- e, ee, se
        const m1 = try readFrame(rdr, &msg_buf);
        _ = try handshake.readMessage(m1, &payload_buf);
    } else {
        const m0 = try readFrame(rdr, &msg_buf);
        _ = handshake.readMessage(m0, &payload_buf) catch |err| {
            switch (err) {
                error.AuthenticationFailed => {
                    log.warn("Peer does not hold correct public key. Aborting.", .{});
                    return error.PeerDoesNotHoldPubkey;
                },
                else => {
                    return err;
                },
            }
        };

        if (!peer_map.contains(handshake.rs.?)) {
            log.warn("Peer tried connecting with unknown pubkey. Aborting.", .{});
            // Should probably close the connection. Will handle this upstream.
            return error.UnknownPeer;
        }

        const l1 = try handshake.writeMessage(&.{}, &msg_buf);
        try sendFrame(writer, msg_buf[0..l1]);
    }

    std.debug.assert(handshake.isComplete());
    var states = handshake.split();

    states.@"0".cipher.pad = true;
    states.@"1".cipher.pad = true;

    return .{
        .io = io,
        .alloc = alloc,
        .opts = opts,
        .read = if (opts.initiator) states.@"1" else states.@"0",
        .write = if (opts.initiator) states.@"0" else states.@"1",
        .read_buf = read_buf,
        .write_buf = write_buf,
        .plain_buf = plain_buf,
    };
}

fn sendFrame(writer: *Io.Writer, data: []const u8) !void {
    if (data.len > noisey.MAX_MESSAGE_LENGTH)
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
    const written = try self.write.encryptWithAd("", data, self.write_buf);
    std.debug.assert(written == noisey.MAX_MESSAGE_LENGTH);

    const bytes = self.write_buf[0..written];

    try sendFrame(writer, bytes);
}

/// The returned slice is valid until the next call to recv.
pub fn recv(self: *NoiseSession, rdr: *Io.Reader) ![]const u8 {
    const frame = try readFrame(rdr, self.read_buf);

    const got = try self.read.decryptWithAd("", frame, self.plain_buf);

    return self.plain_buf[0..got];
}

/// Sends some data, messagepack encoded.
pub fn sendT(self: *NoiseSession, writer: *Io.Writer, alloc: Allocator, that: anytype) !void {
    const data = try serde.msgpack.toSlice(alloc, that);
    try self.send(writer, data);
}

/// Recieves some data, messagepack encoded. Performs no validation on the recieved data.
/// Perhaps I can write .validate methods on my wire types.
pub fn recvT(self: *NoiseSession, comptime T: type, rdr: *Io.Reader, alloc: Allocator) !T {
    const bytes = try self.recv(rdr);

    return try serde.msgpack.fromSlice(T, alloc, bytes);
}
