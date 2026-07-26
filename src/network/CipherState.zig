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

const std = @import("std");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const assert = std.debug.assert;
pub const KEY_LENGTH = Aes256Gcm.key_length;
pub const TAG_LENGTH = Aes256Gcm.tag_length;
pub const NONCE_LENGTH = Aes256Gcm.nonce_length;
const testing = std.testing;

const CipherState = @This();

key: ?[KEY_LENGTH]u8,
nonce: u64,

pub const Error = error{
    NonceExhausted,
    DecryptionFailed,
    InvalidLength,
};

pub fn init(key: ?[KEY_LENGTH]u8) CipherState {
    return .{
        .key = key,
        .nonce = 0,
    };
}

pub fn deinit(self: *CipherState) void {
    if (self.key) |*k| std.crypto.secureZero(u8, k);
    self.key = null;
    self.nonce = 0;
}

/// Noise nonces are the 64 bit counter, big endian, in the final 8 bytes of a
/// 96 bit AEAD nonce.
fn nonceBytes(counter: u64) [NONCE_LENGTH]u8 {
    var nonce: [NONCE_LENGTH]u8 = @splat(0);
    std.mem.writeInt(u64, nonce[4..], counter, .big);

    return nonce;
}

/// Writes `plaintext.len` bytes of ciphertext followed by a `TAG_LENGTH` byte
/// tag into `out`, returning the total bytes written.
///
/// `out` may alias `plaintext`: AES-GCM produces the ciphertext block by block
/// and only then authenticates it, so encrypting in place is well defined.
///
/// With no key set the plaintext is copied through untouched, as the Noise
/// spec requires before the first `mixKey`.
pub fn aeadEncrypt(self: *CipherState, ad: []const u8, plaintext: []const u8, out: []u8) Error!usize {
    if (self.key) |k| {
        assert(out.len >= plaintext.len + TAG_LENGTH);

        if (self.nonce == std.math.maxInt(u64)) return error.NonceExhausted;

        Aes256Gcm.encrypt(
            out[0..plaintext.len],
            out[plaintext.len..][0..TAG_LENGTH],
            plaintext,
            ad,
            nonceBytes(self.nonce),
            k,
        );

        self.nonce += 1;

        return plaintext.len + TAG_LENGTH;
    } else {
        @branchHint(.unlikely);
        assert(out.len >= plaintext.len);
        @memcpy(out[0..plaintext.len], plaintext);

        return plaintext.len;
    }
}

/// Authenticates and decrypts `ciphertext` (payload followed by its
/// `TAG_LENGTH` byte tag) into `out`, returning the plaintext length.
///
/// `out` may alias `ciphertext`: the tag is checked over the whole ciphertext
/// before any plaintext is written, so decrypting in place is well defined.
/// `out` is left undefined if authentication fails.
///
/// `ciphertext` arrives from a remote peer, so a runt message is an error
/// rather than an assertion.
pub fn aeadDecrypt(self: *CipherState, ad: []const u8, ciphertext: []const u8, out: []u8) Error!usize {
    if (self.key) |k| {
        if (ciphertext.len < TAG_LENGTH) return error.InvalidLength;

        const payload_len = ciphertext.len - TAG_LENGTH;
        assert(out.len >= payload_len);

        if (self.nonce == std.math.maxInt(u64)) return error.NonceExhausted;

        Aes256Gcm.decrypt(
            out[0..payload_len],
            ciphertext[0..payload_len],
            ciphertext[payload_len..][0..TAG_LENGTH].*,
            ad,
            nonceBytes(self.nonce),
            k,
        ) catch return error.DecryptionFailed;

        self.nonce += 1;

        return payload_len;
    } else {
        @branchHint(.unlikely);
        assert(out.len >= ciphertext.len);
        @memcpy(out[0..ciphertext.len], ciphertext);

        return ciphertext.len;
    }
}

const TEST_KEY: [KEY_LENGTH]u8 = @splat(0xab);

test "encrypt then decrypt round trip" {
    var enc = CipherState.init(TEST_KEY);
    defer enc.deinit();
    var dec = CipherState.init(TEST_KEY);
    defer dec.deinit();

    const plaintext = "the quick brown fox";
    const ad = "associated data";

    var ciphertext: [plaintext.len + TAG_LENGTH]u8 = undefined;
    const written = try enc.aeadEncrypt(ad, plaintext, &ciphertext);
    try testing.expectEqual(plaintext.len + TAG_LENGTH, written);

    var out: [plaintext.len]u8 = undefined;
    const read = try dec.aeadDecrypt(ad, ciphertext[0..written], &out);
    try testing.expectEqualStrings(plaintext, out[0..read]);
}

test "empty plaintext is still authenticated" {
    var enc = CipherState.init(TEST_KEY);
    defer enc.deinit();
    var dec = CipherState.init(TEST_KEY);
    defer dec.deinit();

    var ciphertext: [TAG_LENGTH]u8 = undefined;
    const written = try enc.aeadEncrypt("", "", &ciphertext);
    try testing.expectEqual(TAG_LENGTH, written);

    var out: [0]u8 = undefined;
    try testing.expectEqual(0, try dec.aeadDecrypt("", &ciphertext, &out));

    // A flipped tag bit must still be caught with no payload to speak of.
    ciphertext[0] ^= 1;
    var dec2 = CipherState.init(TEST_KEY);
    defer dec2.deinit();
    try testing.expectError(error.DecryptionFailed, dec2.aeadDecrypt("", &ciphertext, &out));
}

test "nonce advances once per message and matches the Noise encoding" {
    var enc = CipherState.init(TEST_KEY);
    defer enc.deinit();

    try testing.expectEqual(0, enc.nonce);

    var buf: [16 + TAG_LENGTH]u8 = undefined;
    _ = try enc.aeadEncrypt("", "0123456789abcdef", &buf);
    try testing.expectEqual(1, enc.nonce);
    _ = try enc.aeadEncrypt("", "0123456789abcdef", &buf);
    try testing.expectEqual(2, enc.nonce);

    // Third message: check it byte for byte against the counter placed big
    // endian in the last 8 bytes of a 12 byte nonce.
    var expected: [16 + TAG_LENGTH]u8 = undefined;
    var nonce: [NONCE_LENGTH]u8 = @splat(0);
    std.mem.writeInt(u64, nonce[4..], 2, .big);
    Aes256Gcm.encrypt(
        expected[0..16],
        expected[16..][0..TAG_LENGTH],
        "0123456789abcdef",
        "",
        nonce,
        TEST_KEY,
    );

    _ = try enc.aeadEncrypt("", "0123456789abcdef", &buf);
    try testing.expectEqualSlices(u8, &expected, &buf);
}

test "decrypting out of step with the sender fails" {
    var enc = CipherState.init(TEST_KEY);
    defer enc.deinit();
    var dec = CipherState.init(TEST_KEY);
    defer dec.deinit();

    var first: [4 + TAG_LENGTH]u8 = undefined;
    _ = try enc.aeadEncrypt("", "aaaa", &first);
    var second: [4 + TAG_LENGTH]u8 = undefined;
    _ = try enc.aeadEncrypt("", "bbbb", &second);

    // Receiver is at nonce 0, so the second message will not authenticate.
    var out: [4]u8 = undefined;
    try testing.expectError(error.DecryptionFailed, dec.aeadDecrypt("", &second, &out));
}

test "tampered ciphertext and mismatched ad are rejected" {
    const plaintext = "attack at dawn";

    var ciphertext: [plaintext.len + TAG_LENGTH]u8 = undefined;
    {
        var enc = CipherState.init(TEST_KEY);
        defer enc.deinit();
        _ = try enc.aeadEncrypt("ad", plaintext, &ciphertext);
    }

    var out: [plaintext.len]u8 = undefined;

    {
        var dec = CipherState.init(TEST_KEY);
        defer dec.deinit();
        try testing.expectError(error.DecryptionFailed, dec.aeadDecrypt("different ad", &ciphertext, &out));
    }

    {
        var flipped = ciphertext;
        flipped[0] ^= 0x80;

        var dec = CipherState.init(TEST_KEY);
        defer dec.deinit();
        try testing.expectError(error.DecryptionFailed, dec.aeadDecrypt("ad", &flipped, &out));
    }

    {
        var wrong_key: [KEY_LENGTH]u8 = @splat(0xcd);
        var dec = CipherState.init(wrong_key);
        defer dec.deinit();
        try testing.expectError(error.DecryptionFailed, dec.aeadDecrypt("ad", &ciphertext, &out));
        wrong_key = @splat(0);
    }
}

test "a runt ciphertext is an error, not a panic" {
    var dec = CipherState.init(TEST_KEY);
    defer dec.deinit();

    var out: [64]u8 = undefined;
    const runt: [TAG_LENGTH - 1]u8 = @splat(0);
    try testing.expectError(error.InvalidLength, dec.aeadDecrypt("", &runt, &out));
}

test "a null key passes data through untouched" {
    var state = CipherState.init(null);
    defer state.deinit();

    const plaintext = "not encrypted";
    var out: [plaintext.len]u8 = undefined;

    const written = try state.aeadEncrypt("ignored ad", plaintext, &out);
    try testing.expectEqual(plaintext.len, written);
    try testing.expectEqualStrings(plaintext, &out);
    // No key means no nonce consumption.
    try testing.expectEqual(0, state.nonce);

    var back: [plaintext.len]u8 = undefined;
    const read = try state.aeadDecrypt("ignored ad", &out, &back);
    try testing.expectEqualStrings(plaintext, back[0..read]);
}

test "nonce exhaustion is reported rather than reused" {
    var enc = CipherState.init(TEST_KEY);
    defer enc.deinit();
    enc.nonce = std.math.maxInt(u64);

    var buf: [4 + TAG_LENGTH]u8 = undefined;
    try testing.expectError(error.NonceExhausted, enc.aeadEncrypt("", "aaaa", &buf));

    var dec = CipherState.init(TEST_KEY);
    defer dec.deinit();
    dec.nonce = std.math.maxInt(u64);
    var out: [4]u8 = undefined;
    try testing.expectError(error.NonceExhausted, dec.aeadDecrypt("", &buf, &out));
}

test "encrypting and decrypting in place" {
    var enc = CipherState.init(TEST_KEY);
    defer enc.deinit();
    var dec = CipherState.init(TEST_KEY);
    defer dec.deinit();

    const plaintext = "in place payload, long enough to span several AES blocks";

    // This is the layout NoiseSession relies on: one buffer holding the
    // plaintext, with room for the tag in the tail.
    var buf: [plaintext.len + TAG_LENGTH]u8 = undefined;
    @memcpy(buf[0..plaintext.len], plaintext);

    const written = try enc.aeadEncrypt("ad", buf[0..plaintext.len], &buf);
    try testing.expectEqual(buf.len, written);
    try testing.expect(!std.mem.eql(u8, plaintext, buf[0..plaintext.len]));

    const read = try dec.aeadDecrypt("ad", &buf, &buf);
    try testing.expectEqual(plaintext.len, read);
    try testing.expectEqualStrings(plaintext, buf[0..read]);
}

test "deinit wipes the key" {
    var state = CipherState.init(TEST_KEY);
    state.nonce = 7;
    state.deinit();

    try testing.expectEqual(null, state.key);
    try testing.expectEqual(0, state.nonce);
}
