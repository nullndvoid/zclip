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

//! Packets for the Network protocol.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const serde = @import("serde");

const Packet = @This();

const MAGIC = "zclip";

/// Reject if not present.
magic: []const u8 = MAGIC,
/// Will later be used to parse packets or reject them. Ignored for now.
protocol_version: u8,
payload: Payload,

pub const Payload = struct {};

/// User should free returned packet when no longer needed e.g. after sending.
/// Perhaps use an Arena to handle this for you.
pub fn fromReader(rdr: *Io.Reader, allocator: Allocator) !Packet {
    const packet = try serde.msgpack.fromReader(Packet, allocator, rdr);

    if (!std.mem.eql(u8, packet.magic, MAGIC))
        return error.InvalidMagic;

    return packet;
}
