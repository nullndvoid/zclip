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

//! Cipher state abstraction for the Noise protocol (we only actually care
//! about IK pattern and AES256-GCM).
//!
//! This handles padding and framing (prefix with u16 BE) for us.
//!
//! This way consumers calling `decryptWithAd` should have the right data.

const std = @import("std");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const assert = std.debug.assert;

const NoiseSession = @import("NoiseSession.zig");

const CipherState = @This();

/// 2 byte length prefix + padded payload.
const PLAIN_LENGTH = NoiseSession.MESSAGE_LENGTH - NoiseSession.AEAD_TAG_LENGTH;

key: ?[32]u8,
nonce: u64,
/// Always used for padding plaintext messages to avoid a heap allocation.
msgbuf: [PLAIN_LENGTH]u8,

pub const CipherStateError = error{
    NonceExhausted,
    DecryptionFailed,
    InvalidLength,
};

pub fn init(key: ?[32]u8) CipherState {
    return .{
        .key = key,
        .nonce = 0,
        .msgbuf = @splat(0),
    };
}

pub fn deinit(self: *CipherState) void {
    if (self.key) |*k| std.crypto.secureZero(u8, k);
    self.key = null;

    std.crypto.secureZero(u8, &self.msgbuf);
    self.nonce = 0;
}

/// `ciphertext` must be of size `NoiseSession.MESSAGE_LENGTH` i.e. 65535.
///
/// `plaintext` will be padded for you. Returns `error.InvalidLength` if
/// `plaintext` is larger than `MAX_PAYLOAD_LENGTH`.
///
/// Returned value is simply the same slice passed in for `ciphertext`.
pub fn encryptWithAd(self: *CipherState, ad: []const u8, plaintext: []const u8, ciphertext: []u8) CipherStateError![]const u8 {
    assert(ciphertext.len == NoiseSession.MESSAGE_LENGTH);

    const padded_plaintext = try self.pad(plaintext);

    if (self.key) |k| {
        if (self.nonce == std.math.maxInt(u64)) return error.NonceExhausted;

        var nonce: [12]u8 = @splat(0);
        std.mem.writeInt(u64, nonce[4..], self.nonce, .big);

        Aes256Gcm.encrypt(
            ciphertext[0..PLAIN_LENGTH],
            ciphertext[PLAIN_LENGTH..][0..NoiseSession.AEAD_TAG_LENGTH],
            padded_plaintext,
            ad,
            nonce,
            k,
        );

        self.nonce += 1;
    } else {
        @branchHint(.unlikely);
        @memcpy(ciphertext[0..PLAIN_LENGTH], padded_plaintext);
        std.crypto.secureZero(u8, ciphertext[PLAIN_LENGTH..]);
    }

    return ciphertext;
}

/// `ciphertext` must be of size `NoiseSession.MESSAGE_LENGTH` i.e. 65535.
///
/// The returned slice is clobbered on the next call to `encryptWithAd` or
/// `decryptWithAd`, so you should dupe this if needed.
pub fn decryptWithAd(self: *CipherState, ad: []const u8, ciphertext: []const u8) CipherStateError![]const u8 {
    assert(ciphertext.len == NoiseSession.MESSAGE_LENGTH);

    if (self.key) |k| {
        if (self.nonce == std.math.maxInt(u64)) return error.NonceExhausted;

        var nonce: [12]u8 = @splat(0);
        std.mem.writeInt(u64, nonce[4..], self.nonce, .big);

        Aes256Gcm.decrypt(
            &self.msgbuf,
            ciphertext[0..PLAIN_LENGTH],
            ciphertext[PLAIN_LENGTH..][0..NoiseSession.AEAD_TAG_LENGTH].*,
            ad,
            nonce,
            k,
        ) catch return error.DecryptionFailed;

        self.nonce += 1;
    } else {
        @branchHint(.unlikely);
        @memcpy(&self.msgbuf, ciphertext[0..PLAIN_LENGTH]);
    }

    return self.unpad();
}

/// Pads the plaintext and prefixes the length.
///
/// Returns `error.InvalidLength` if the input is larger than
/// `MAX_PAYLOAD_LENGTH`. I will, in the future, packetise long inputs so
/// this case shan't be reachable.
///
/// This lives until the next clobber of `msgbuf`, so callers
/// should send the data in plaintext ASAP.
fn pad(self: *CipherState, plaintext: []const u8) CipherStateError![]const u8 {
    if (plaintext.len > NoiseSession.MAX_PAYLOAD_LENGTH) return error.InvalidLength;

    std.crypto.secureZero(u8, &self.msgbuf);

    std.mem.writeInt(u16, self.msgbuf[0..2], @intCast(plaintext.len), .big);
    @memcpy(self.msgbuf[2..][0..plaintext.len], plaintext);

    return &self.msgbuf;
}

/// Given some decrypted plaintext in `msgbuf`, recovers the unpadded version as
/// a slice. Returns a slice into the `msgbuf`.
fn unpad(self: *CipherState) CipherStateError![]const u8 {
    const len = std.mem.readInt(u16, self.msgbuf[0..2], .big);
    if (len > NoiseSession.MAX_PAYLOAD_LENGTH) return error.InvalidLength;

    return self.msgbuf[2..][0..len];
}
