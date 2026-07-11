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
