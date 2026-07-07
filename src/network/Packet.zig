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
//!
//! TODO: Packetise large payloads.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Serde = @import("serde");

const Packet = @This();

const MAGIC = "zclip";

/// Reject if not present.
magic: []const u8 = MAGIC,
/// Will later be used to parse packets or reject them. Ignored for now.
protocol_version: u8,
payload: Payload,

pub const Payload = struct {};

pub fn validate(self: *const Packet) bool {
    if (!std.mem.eql(u8, self.magic, MAGIC))
        return false;

    return true;
}
