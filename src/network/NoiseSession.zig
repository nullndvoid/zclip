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
const assert = std.debug.assert;
const testing = std.testing;

const serde = @import("serde");

const Network = @import("../Network.zig");
const CipherState = @import("CipherState.zig");
const Error = CipherState.Error;
pub const AEAD_TAG_LENGTH = CipherState.TAG_LENGTH;
const HandshakeState = @import("HandshakeState.zig");
const Packet = @import("Packet.zig");

const log = std.log.scoped(.NoiseSession);

const NoiseSession = @This();

/// Overhead per frame: the AEAD tag, plus a u16 length prefix used to
/// recover the true payload length after padding.
const FRAME_OVERHEAD = AEAD_TAG_LENGTH + 2;

/// Handshake messages are small but size generously.
const HANDSHAKE_BUF_LEN = 256;

pub const Options = struct {
    /// Every encrypted transport message is padded and encrypted to exactly
    /// this many bytes, so ciphertext size never reveals payload length.
    /// Smaller values shrink memory and bandwidth, at the cost of a smaller
    /// `maxPayloadLength`, which is `frame_length`, less 18 bytes.
    frame_length: u16 = 65535,
};

io: Io,
opts: Options,
alloc: Allocator,
read: CipherState,
write: CipherState,
read_buf: []u8,
write_buf: []u8,
/// The peers public key.
peer_pubkey: [32]u8,

/// Makes no attempt to tell peer about this.
pub fn deinit(self: *NoiseSession) void {
    self.read.deinit();
    self.write.deinit();

    std.crypto.secureZero(u8, self.read_buf);

    self.alloc.free(self.read_buf);
    self.alloc.free(self.write_buf);
}

/// Initiator if `peer_pubkey` is not null.
///
/// All messages are sent padded, prefixed with their actual size.
///
/// * AEAD is AES256-GCM
/// * DH is x25519
/// * Hash function is SHA-256.
///
/// ## Security Notes
///
/// Ensure that the validity of the peers pubkey is checked if you did not
/// initiate the session.
pub fn init(
    io: Io,
    alloc: Allocator,
    rdr: *Io.Reader,
    writer: *Io.Writer,
    identity: Network.Identity,
    peer_pubkey: ?[32]u8,
    opts: Options,
) !NoiseSession {
    const initiator = peer_pubkey != null;

    const split =
        try handshake(io, rdr, writer, identity, peer_pubkey);

    const read_buf = try alloc.alloc(u8, opts.frame_length);
    errdefer alloc.free(read_buf);

    const write_buf = try alloc.alloc(u8, opts.frame_length);
    errdefer alloc.free(write_buf);

    return .{
        .io = io,
        .alloc = alloc,
        .read = if (initiator) split.@"1" else split.@"0",
        .write = if (initiator) split.@"0" else split.@"1",
        .read_buf = read_buf,
        .write_buf = write_buf,
        .opts = opts,
        .peer_pubkey = split.@"2",
    };
}

pub const Result = struct {};

/// Performs the Noise handshake over `rdr` and `writer`.
///
/// If `remote_pubkey` is not null, then you are the initiator.
///
/// Returns a triple of two `CipherState`'s, and the remote public key.
///
/// If initiator, first is writes, second reads.
/// If responder, the converse applies.
///
/// ## Security Notes
///
/// Take care to check the public key of the remote peer exists in DB
/// if this succeeds.
///
fn handshake(
    io: Io,
    rdr: *Io.Reader,
    writer: *Io.Writer,
    identity: Network.Identity,
    remote_pubkey: ?[32]u8,
) !struct { CipherState, CipherState, [32]u8 } {
    const initiator = remote_pubkey != null;
    const s = HandshakeState.KeyPair{
        .public = identity.public_key,
        .secret = identity.private_key,
    };

    var shaker = try HandshakeState.init(
        initiator,
        &.{},
        s,
        remote_pubkey,
    );

    var msg_buf: [HANDSHAKE_BUF_LEN]u8 = undefined;
    var payload_buf: [HANDSHAKE_BUF_LEN]u8 = undefined;

    if (initiator) {
        const len0 = try shaker.writeMessage(io, &.{}, &msg_buf);
        try sendFrame(writer, msg_buf[0..len0]);

        const m1 = try readFrame(rdr, &msg_buf);
        _ = try shaker.readMessage(m1, &payload_buf);
    } else {
        const m0 = try readFrame(rdr, &msg_buf);
        _ = shaker.readMessage(m0, &payload_buf) catch |err| switch (err) {
            error.DecryptionFailed => {
                log.warn("Peer does not hold correct public key. Aborting.", .{});
                return error.PeerDoesNotHoldPubkey;
            },
            else => return err,
        };

        std.debug.assert(shaker.rs != null);

        const l1 = try shaker.writeMessage(io, &.{}, &msg_buf);
        try sendFrame(writer, msg_buf[0..l1]);
    }

    std.debug.assert(shaker.done());

    const first, const second = shaker.split();
    const peer_publickey = shaker.rs.?;

    return .{ first, second, peer_publickey };
}

fn sendFrame(writer: *Io.Writer, data: []const u8) !void {
    assert(data.len <= std.math.maxInt(u16));

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

/// The largest payload `send` will accept for this session's `frame_length`.
pub fn maxPayloadLength(self: *const NoiseSession) u16 {
    return self.opts.frame_length - FRAME_OVERHEAD;
}

pub fn send(self: *NoiseSession, writer: *Io.Writer, data: []const u8) !void {
    const bytes = try encryptWithAdFramed(&self.write, "", data, self.write_buf);

    try sendFrame(writer, bytes);
}

/// The returned slice is valid until the next call to recv.
pub fn recv(self: *NoiseSession, rdr: *Io.Reader) ![]const u8 {
    const frame = try readFrame(rdr, self.read_buf);

    if (frame.len != self.read_buf.len) return error.InvalidLength;

    return try decryptWithAdFramed(&self.read, "", frame, self.read_buf);
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

/// `ciphertext` doubles as the pad buffer: `plaintext` is padded into it,
/// then encrypted in place. Its length fixes the frame size for this
/// message, and therefore the max payload accepted (see `pad`).
///
/// Returned value is simply the same slice passed in for `ciphertext`.
fn encryptWithAdFramed(self: *CipherState, ad: []const u8, plaintext: []const u8, ciphertext: []u8) Error![]const u8 {
    const padded_plaintext = try pad(plaintext, ciphertext);

    _ = try self.aeadEncrypt(ad, padded_plaintext, ciphertext);

    return ciphertext;
}

/// `ciphertext` must be exactly `buf.len` bytes (the caller's fixed frame
/// size) and may alias `buf`.
fn decryptWithAdFramed(self: *CipherState, ad: []const u8, ciphertext: []const u8, buf: []u8) Error![]const u8 {
    assert(ciphertext.len == buf.len);

    const n = try self.aeadDecrypt(ad, ciphertext, buf);

    return try unpad(buf[0..n]);
}

/// Pads the plaintext to a constant length equal to `buf.len - TAG_LENGTH`,
/// prefixed with its actual length, so the ciphertext never varies in size
/// regardless of payload length.
///
/// Returns `error.InvalidLength` if the input is larger than fits (i.e.
/// larger than `buf.len - FRAME_OVERHEAD`). I will, in the future, packetise
/// long inputs so this case shan't be reachable.
///
/// `buf` must be at least `FRAME_OVERHEAD` bytes; the returned slice is
/// exactly `buf.len - AEAD_TAG_LENGTH` bytes.
fn pad(plaintext: []const u8, buf: []u8) Error![]const u8 {
    assert(buf.len > FRAME_OVERHEAD);
    const plain_length = buf.len - AEAD_TAG_LENGTH;

    if (plaintext.len > plain_length - 2) return error.InvalidLength;

    std.crypto.secureZero(u8, buf[0..plain_length]);
    std.mem.writeInt(u16, buf[0..2], @intCast(plaintext.len), .big);
    @memcpy(buf[2..][0..plaintext.len], plaintext);

    return buf[0..plain_length];
}

/// Given some decrypted, padded plaintext in `buf`, recovers the unpadded
/// version as a slice. `buf` must be exactly the authenticated plaintext
/// (see `decryptWithAdFramed`).
fn unpad(buf: []const u8) Error![]const u8 {
    if (buf.len < 2) return error.InvalidLength;

    const len = std.mem.readInt(u16, buf[0..2], .big);
    if (len > buf.len - 2) return error.InvalidLength;

    return buf[2..][0..len];
}

const ConnectResult = struct { NoiseSession, Io.net.Stream };

/// Connects to `path` and performs the initiator side of the handshake.
fn connectAndHandshake(
    io: Io,
    alloc: Allocator,
    path: []const u8,
    identity: Network.Identity,
    peer_pubkey: [32]u8,
    opts: Options,
) !ConnectResult {
    const addr = try Io.net.UnixAddress.init(path);
    const stream = try addr.connect(io);
    errdefer stream.close(io);

    var read_buf: [512]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var sock_rdr = stream.reader(io, &read_buf);
    var sock_writer = stream.writer(io, &write_buf);

    const session = try NoiseSession.init(
        io,
        alloc,
        &sock_rdr.interface,
        &sock_writer.interface,
        identity,
        peer_pubkey,
        opts,
    );

    return .{ session, stream };
}

const SessionPair = struct {
    initiator: NoiseSession,
    initiator_stream: Io.net.Stream,
    responder: NoiseSession,
    responder_stream: Io.net.Stream,

    fn deinit(self: *SessionPair, io: Io) void {
        self.initiator.deinit();
        self.responder.deinit();
        self.initiator_stream.close(io);
        self.responder_stream.close(io);
    }
};

fn handshakePair(io: Io, alloc: Allocator, opts: Options) !SessionPair {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/noise_test.sock", .{&tmp.sub_path});
    defer alloc.free(path);

    const addr = try Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    const initiator_identity = Network.Identity.generate(io);
    const responder_identity = Network.Identity.generate(io);

    var future = try io.concurrent(
        connectAndHandshake,
        .{
            io,
            alloc,
            path,
            initiator_identity,
            responder_identity.public_key,
            opts,
        },
    );

    const responder_stream = try server.accept(io);
    errdefer responder_stream.close(io);

    var r_read_buf: [512]u8 = undefined;
    var r_write_buf: [512]u8 = undefined;
    var r_sock_rdr = responder_stream.reader(io, &r_read_buf);
    var r_sock_writer = responder_stream.writer(io, &r_write_buf);

    const responder_session = try NoiseSession.init(
        io,
        alloc,
        &r_sock_rdr.interface,
        &r_sock_writer.interface,
        responder_identity,
        null,
        opts,
    );

    const initiator_session, const initiator_stream = try future.await(io);

    return .{
        .initiator = initiator_session,
        .initiator_stream = initiator_stream,
        .responder = responder_session,
        .responder_stream = responder_stream,
    };
}

test "handshake identifies both peers correctly" {
    const io = testing.io;
    const alloc = testing.allocator;

    const initiator_identity = Network.Identity.generate(io);
    const responder_identity = Network.Identity.generate(io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/noise_test.sock", .{&tmp.sub_path});
    defer alloc.free(path);

    const addr = try Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var future = try io.concurrent(connectAndHandshake, .{
        io, alloc, path, initiator_identity, responder_identity.public_key, Options{},
    });

    const responder_stream = try server.accept(io);
    defer responder_stream.close(io);

    var r_read_buf: [512]u8 = undefined;
    var r_write_buf: [512]u8 = undefined;
    var r_sock_rdr = responder_stream.reader(io, &r_read_buf);
    var r_sock_writer = responder_stream.writer(io, &r_write_buf);

    var responder_session = try NoiseSession.init(io, alloc, &r_sock_rdr.interface, &r_sock_writer.interface, responder_identity, null, .{});
    defer responder_session.deinit();

    var initiator_session, const initiator_stream = try future.await(io);
    defer initiator_session.deinit();
    defer initiator_stream.close(io);

    // Each side's peer_pubkey is the *other* side's static public key.
    try testing.expectEqualSlices(u8, &responder_identity.public_key, &initiator_session.peer_pubkey);
    try testing.expectEqualSlices(u8, &initiator_identity.public_key, &responder_session.peer_pubkey);
}
