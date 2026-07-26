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

//! Handshake state abstraction for peer to peer comms. Mostly used for my internal
//! Noise IK protocol implementation. Not guaranteed to support all of the features,
//! but this file should mostly be complete once done. Yay, tautologies.
//!
//! Note that I only attempt to support aes256gcm, x25519, and sha256, so sizes of things
//! might be hardcoded.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const DH_LENGTH = std.crypto.dh.X25519.shared_length;

const CipherState = @import("CipherState.zig");
const NoiseSession = @import("NoiseSession.zig");
const MESSAGE_LENGTH = NoiseSession.MESSAGE_LENGTH;
const SymmetricState = @import("SymmetricState.zig");

const HandshakeState = @This();

pub const Key = [CipherState.KEY_LENGTH]u8;
pub const SharedKey = [DH_LENGTH]u8;

/// For now we just support the one fixed protocol.
pub const PROTOCOL_NAME = "Noise_IK_25519_AESGCM_SHA256";

const MessagePattern = []const MessageToken;

const IK_MESSAGE_ONE = [_]MessageToken{ .e, .es, .s, .ss };
const IK_MESSAGE_TWO = [_]MessageToken{ .e, .ee, .se };

/// The only pattern we actually need. Even index is initiator. Odd index is
/// responder.
const IK = [_]MessagePattern{
    &IK_MESSAGE_ONE,
    &IK_MESSAGE_TWO,
};

pub const KeyPair = struct {
    public: Key,
    secret: Key,

    /// Generates a DH keypair.
    pub fn generate(io: Io) KeyPair {
        const kp = std.crypto.dh.X25519.KeyPair.generate(io);

        return .{
            .public = kp.public_key,
            .secret = kp.secret_key,
        };
    }

    pub fn dh(keypair: KeyPair, public_key: Key) HandshakeError!SharedKey {
        const shared = std.crypto.dh.X25519.scalarmult(
            keypair.secret,
            public_key,
        ) catch return error.PublicKeyInvalid;
        return shared;
    }
};

/// I don't care about PSK support or anything advanced, so this should
/// suffice.
const MessageToken = enum(u8) {
    e,
    s,
    ee,
    es,
    se,
    ss,
};

symmetric_state: SymmetricState,
/// Local static keypair, if any.
s: ?KeyPair = null,
/// Local ephemeral keypair, if any.
e: ?KeyPair = null,
/// Remote parties public static key, if any.
///
/// Conveniently, our DH pubkey is also 32 bytes long.
rs: ?Key = null,
/// Remote parties public ephemeral key, if any.
re: ?Key = null,
/// Set if this party is the initiator.
initiator: bool,
/// A sequence of message patterns to be processed.
///
/// We only claim to support Noise IK so I might not need to spend much effort
/// parsing any sequence of tokens etc.
///
/// Even indices sent by initiator, odd by responder.
message_patterns: []const MessagePattern = &IK,
/// Current index of `message_patterns`.
pattern_idx: usize = 0,

pub const HandshakeError = error{
    /// The remote static public is missing, but you are the initiator!
    MissingRemoteStatic,
    /// You are not the initiator but gave a remote static key!
    RemoteStaticGiven,
    /// You are writing or reading a message when you should not be.
    OutOfTurn,
    /// The DH public key used was invalid.
    PublicKeyInvalid,
} || CipherState.CipherStateError;

/// Since we only claim to support Noise IK, this initialiser reflects this.
///
/// Maybe another time I can extract this all into a separate library, the
/// previous one was very lazily written by clankers, but this shittier code
/// is all mine lol.
pub fn init(initiator: bool, prologue: []const u8, s: ?KeyPair, rs: ?Key) HandshakeError!HandshakeState {
    var sym = SymmetricState.init(PROTOCOL_NAME);
    sym.mixHash(prologue);

    // Upholds our pre-message invariant for Noise IK.
    if (initiator and rs == null) return error.MissingRemoteStatic;
    if (!initiator and rs != null) return error.RemoteStaticGiven;

    // Now it is sufficient to check for presence of rs lol.
    if (rs) |rspk| sym.mixHash(&rspk);

    // End of pre-messages. Should be done now.
    return .{
        .initiator = initiator,
        .s = s,
        .rs = rs,
        .symmetric_state = sym,
    };
}

/// Fetches and 'deletes' the next message pattern from `self.message_patterns`.
///
/// Processes each message token in the pattern.
pub fn writeMessage(
    self: *HandshakeState,
    io: Io,
    payload: []const u8,
    message_buffer: []u8,
) HandshakeError!usize {
    if ((self.initiator and self.pattern_idx % 2 == 1) or
        (!self.initiator and self.pattern_idx % 2 == 0))
        return error.OutOfTurn;

    assert(self.pattern_idx < self.message_patterns.len);

    const pattern = self.message_patterns[self.pattern_idx];
    var pos: usize = 0;

    for (pattern) |token| {
        switch (token) {
            .e => {
                assert(self.e == null);

                self.e = .generate(io);
                const pubkey = self.e.?.public;

                @memcpy(message_buffer[pos..][0..pubkey.len], &pubkey);

                pos += pubkey.len;

                self.symmetric_state.mixHash(&pubkey);
            },
            .s => {
                const s = self.s.?;
                const bytes = try self.symmetric_state.encryptAndHash(
                    &s.public,
                    message_buffer[pos..],
                );

                pos += bytes;
            },
            .ee => {
                const dh = try self.e.?.dh(self.re.?);
                self.symmetric_state.mixKey(dh);
            },
            .es => {
                const dh = try if (self.initiator) self.e.?.dh(self.rs.?) else self.s.?.dh(self.re.?);
                self.symmetric_state.mixKey(dh);
            },
            .se => {
                const dh = try if (self.initiator) self.s.?.dh(self.re.?) else self.e.?.dh(self.rs.?);
                self.symmetric_state.mixKey(dh);
            },
            .ss => {
                self.symmetric_state.mixKey(try self.s.?.dh(self.rs.?));
            },
        }
    }

    pos += try self.symmetric_state.encryptAndHash(payload, message_buffer[pos..]);

    self.pattern_idx += 1;

    return pos;
}

/// Returns the length of the payload.
pub fn readMessage(
    self: *HandshakeState,
    message: []const u8,
    payload_buffer: []u8,
) HandshakeError!usize {
    if ((self.initiator and self.pattern_idx % 2 == 0) or
        (!self.initiator and self.pattern_idx % 2 == 1))
        return error.OutOfTurn;

    assert(self.pattern_idx < self.message_patterns.len);

    const pattern = self.message_patterns[self.pattern_idx];
    var pos: usize = 0;

    for (pattern) |token| {
        switch (token) {
            .e => {
                assert(self.re == null);
                self.re = message[pos..][0..DH_LENGTH].*;
                self.symmetric_state.mixHash(&self.re.?);
                pos += DH_LENGTH;
            },
            .s => {
                assert(self.rs == null);

                const field_len: usize = if (self.symmetric_state.cipher_state.key != null)
                    DH_LENGTH + NoiseSession.AEAD_TAG_LENGTH
                else
                    DH_LENGTH;

                const temp = message[pos..][0..field_len];
                pos += field_len;

                var rs: Key = undefined;
                const n = try self.symmetric_state.decryptAndHash(temp, &rs);
                assert(n == DH_LENGTH);
                self.rs = rs;
            },
            .ee => {
                self.symmetric_state.mixKey(try self.e.?.dh(self.re.?));
            },
            .es => {
                const shared = if (self.initiator)
                    try self.e.?.dh(self.rs.?)
                else
                    try self.s.?.dh(self.re.?);
                self.symmetric_state.mixKey(shared);
            },
            .se => {
                const shared = if (self.initiator)
                    try self.s.?.dh(self.re.?)
                else
                    try self.e.?.dh(self.rs.?);
                self.symmetric_state.mixKey(shared);
            },
            .ss => {
                self.symmetric_state.mixKey(try self.s.?.dh(self.rs.?));
            },
        }
    }

    self.pattern_idx += 1;

    return try self.symmetric_state.decryptAndHash(message[pos..], payload_buffer);
}

/// Returns true when the handshake is complete.
pub fn done(self: *const HandshakeState) bool {
    return (self.pattern_idx >= self.message_patterns.len);
}

pub fn split(self: *HandshakeState) struct { CipherState, CipherState } {
    return self.symmetric_state.split();
}
