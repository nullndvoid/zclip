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

pub const Opts = struct {
    initiator: bool = true,
    pad: bool = true,
};

pub fn init(
    io: Io,
    alloc: Allocator,
    opts: Opts,
    rdr: *Io.Reader,
    writer: *Io.Writer,
    local_keypair: Network.Identity,
    peer_pubkey: []const u8,
    peer_map: *Network.PeerMap,
) !NoiseSession {
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
        const m1 = try readFrame(rdr, &payload_buf);
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

        if (!peer_map.contains(handshake.rs)) {
            log.warn("Peer tried connecting with unknown pubkey. Aborting.", .{});
            // Should probably close the connection. Will handle this upstream.
            return error.UnknownPeer;
        }

        const l1 = try handshake.writeMessage(&.{}, &msg_buf);
        try sendFrame(writer, msg_buf[0..l1]);
    }

    std.debug.assert(handshake.isComplete());
    var states = handshake.split();

    states.@"0".cipher.pad = opts.pad;
    states.@"1".cipher.pad = opts.pad;

    return .{
        .io = io,
        .alloc = alloc,
        .opts = opts,
        .read = if (opts.initiator) states.@"1" else states.@"0",
        .write = if (opts.initiator) states.@"0" else states.@"1",
    };
}

fn sendFrame(writer: *Io.Writer, data: []const u8) !void {
    try writer.writeInt(u16, data.len, .big);
    try writer.writeAll(data);
    try writer.flush();
}

fn readFrame(rdr: *Io.Reader, buf: []u8) ![]const u8 {
    const length = try rdr.takeInt(u16, .big);
    try rdr.readSliceAll(buf[0..length]);

    return buf[0..length];
}
