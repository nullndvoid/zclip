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

//! Networking code for zclip peers.

const std = @import("std");
const Io = std.Io;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;

io: Io,
arena: Arena,

const Network = @This();

pub fn init(io: Io, arena: Arena) !*Network {
    const self = try arena.allocator().create(Network);
    self.* = .{
        .io = io,
        .arena = arena,
    };

    return self;
}

pub const Peer = struct {
    /// Ed25519 public key. Should be 32 bytes in length once base 64 decoded.
    pubkey: []const u8,
    /// A nickname for the remote peer.
    nickname: []const u8,
};
