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

//! Symmetric state abstraction for the Noise protocol (we only actually care
//! about IK pattern and AES256-GCM, not that it matters much at this level).

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HASH_LENGTH = Sha256.digest_length;
const DH_LENGTH = std.crypto.dh.X25519.shared_length;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const secureZero = std.crypto.secureZero;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const CipherState = @import("CipherState.zig");
const NoiseSession = @import("NoiseSession.zig");

const SymmetricState = @This();

chaining_key: [HASH_LENGTH]u8,
hash: [HASH_LENGTH]u8,
cipher_state: CipherState,

pub fn init(protocol_name: []const u8) SymmetricState {
    var hash: [HASH_LENGTH]u8 = @splat(0);
    if (protocol_name.len <= HASH_LENGTH) {
        @memcpy(hash[0..protocol_name.len], protocol_name);
    } else {
        var hasher = Sha256.init(.{});
        hasher.update(protocol_name);
        hash = hasher.finalResult();
    }

    return .{
        .hash = hash,
        .chaining_key = hash,
        .cipher_state = .init(null),
    };
}

pub fn deinit(self: *SymmetricState) void {
    secureZero(u8, &self.hash);
    secureZero(u8, &self.chaining_key);
    self.cipher_state.deinit();
}

/// `num_outputs` should be one of 2, 3.
fn hkdf(ck: [HASH_LENGTH]u8, ikm: []const u8, comptime num_outputs: usize) [num_outputs][32]u8 {
    const prk = HkdfSha256.extract(&ck, ikm);

    var out: [num_outputs * 32]u8 = undefined;
    HkdfSha256.expand(&out, "", prk);

    var result: [num_outputs][32]u8 = undefined;
    inline for (0..num_outputs) |i| {
        result[i] = out[i * 32 ..][0..32].*;
    }
    return result;
}

pub fn mixKey(self: *SymmetricState, ikm: [DH_LENGTH]u8) void {
    const outputs = hkdf(self.chaining_key, &ikm, 2);
    self.chaining_key = outputs[0];

    // HASH_LENGTH is 32 so no need to truncate.
    const temp_key = outputs[1];

    self.cipher_state = .init(temp_key);
}

pub fn mixHash(self: *SymmetricState, data: []const u8) void {
    var hasher = Sha256.init(.{});
    hasher.update(&self.hash);
    hasher.update(data);
    hasher.final(&self.hash);
}

pub fn mixKeyAndHash(self: *SymmetricState, ikm: [DH_LENGTH]u8) void {
    const outputs = hkdf(self.chaining_key, &ikm, 3);
    self.chaining_key = outputs[0];

    const temp_hash = outputs[1];

    // HASH_LENGTH is 32 so no need to truncate.
    const temp_key = outputs[2];

    self.mixHash(&temp_hash);

    self.cipher_state = .init(temp_key);
}

pub fn getHandshakeHash(self: *const SymmetricState) [HASH_LENGTH]u8 {
    return self.hash;
}

/// `ciphertext_buf` must be of size NoiseSession.MESSAGE_LENGTH.
///
/// This buffer backs the returned slice.
pub fn encryptFramed(self: *SymmetricState, plaintext: []const u8, ciphertext_buf: []u8) CipherState.Error![]const u8 {
    const ciphertext = try self.cipher_state.encryptWithAdFramed(
        &self.hash,
        plaintext,
        ciphertext_buf,
    );

    // Deviates from spec since our ciphertext is framed and includes the AEAD tag.
    // This is fine since we are using this code end-to-end.
    self.mixHash(ciphertext);

    return ciphertext;
}

pub fn encryptAndHash(self: *SymmetricState, plaintext: []const u8, out: []u8) CipherState.Error!usize {
    const n = try self.cipher_state.aeadEncrypt(&self.hash, plaintext, out);

    self.mixHash(out[0..n]);

    return n;
}

pub fn decryptAndHash(self: *SymmetricState, ciphertext: []const u8, out: []u8) CipherState.Error!usize {
    const n = try self.cipher_state.aeadDecrypt(&self.hash, ciphertext, out);

    self.mixHash(ciphertext);

    return n;
}

/// `plaintext_buf` must be at least `NoiseSession.MAX_PAYLOAD_LENGTH` bytes long.
///
/// This buffer backs the returned slice.
pub fn decryptFramed(self: *SymmetricState, ciphertext: []const u8, plaintext_buf: []u8) CipherState.Error![]const u8 {
    const plaintext = try self.cipher_state.decryptWithAdFramed(&self.hash, ciphertext);

    // Deviates from spec since our ciphertext is framed and includes the AEAD tag.
    // This is fine since we are using this code end-to-end.
    self.mixHash(ciphertext);

    @memcpy(plaintext_buf[0..plaintext.len], plaintext);

    return plaintext_buf[0..plaintext.len];
}

/// Returns a pair of `CipherState`'s for encryption of transport messages.
pub fn split(self: *SymmetricState) struct { CipherState, CipherState } {
    const outputs = hkdf(self.chaining_key, &.{}, 2);

    // As above, HASH_LENGTH is 32 so no truncation required.
    const temp_key1 = outputs[0];
    const temp_key2 = outputs[1];

    const c1 = CipherState.init(temp_key1);
    const c2 = CipherState.init(temp_key2);

    return .{ c1, c2 };
}
