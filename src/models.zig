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

//! Models for databases and possibly configs. Where these diverge,
//! it shall be made clear.

pub const NetworkPeer = struct {
    /// Peers public key. Base64 encoded. Decoded length should be 32 bytes.
    pubkey: []const u8,

    /// A nickname for the remote peer.
    nickname: []const u8,

    /// The IP address of the remote peer. Null if the remote should only
    /// connect to this one.
    addr: ?[]const u8,

    /// A (locally) unique ID for the peer.
    /// Globally unique IDs could be generated using a hash of one's own public
    /// key.
    id: u8 = 0,
};
