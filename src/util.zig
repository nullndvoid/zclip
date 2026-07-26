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

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Caller should free the returned buffer.
pub fn base64encode(bytes: []const u8, alloc: Allocator) ![]const u8 {
    const len = std.base64.standard.Encoder.calcSize(bytes.len);
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);

    const out = std.base64.standard.Encoder.encode(buf, bytes);

    return out;
}

/// Caller should free the returned buffer.
pub fn base64decode(bytes: []const u8, alloc: Allocator) ![]const u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(bytes);
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);

    try std.base64.standard.Decoder.decode(buf, bytes);

    return buf;
}

/// Non-allocating key encode to base64.
pub fn encodeKey(key: [32]u8) [44]u8 {
    var buf: [44]u8 = undefined;

    const out = std.base64.standard.Encoder.encode(&buf, &key);
    std.debug.assert(out.len == 44);

    return buf;
}

/// Non-allocating key decode from base64.
pub fn decodeKey(b64: []const u8) std.base64.Error![32]u8 {
    var buf: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&buf, b64);

    return buf;
}

test "encode and decode key" {
    const key: [32]u8 = undefined;

    const encoded = encodeKey(key);

    const decoded = try decodeKey(&encoded);

    try std.testing.expectEqualSlices(u8, &key, &decoded);
}
