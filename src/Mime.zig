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

//! Mime-type related code.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Mime = @This();

/// These are the most basic plaintext types. They are all somewhat equivalent.
/// For now I will make no assumptions of UTF-8 encoding.
const text_types = [_][:0]const u8{
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
};

/// List of MIME types.
mime_types: std.ArrayList([:0]const u8) = .empty,

/// To avoid appending plaintext types if we already have text/plain;charset=utf-8
/// or text/plain. We only need one of these!
got_plain_text: bool = false,

/// We get a list of MIME types from the compositor. We want to prefer text,
/// and possibly ignore internal application MIME types. If they are the only
/// type specified, then we can pipe to file -i - and check the encoding of the
/// input. If it's text we convert to UTF-8.
///
/// If we see text/html and another plain text type, text/html is allowed to win.
///
/// However if we see an image or something, we prefer to keep this. Same for audio
/// and videos.
///
/// For simplicity we make a list of MIME types and select from these.
pub fn choose(self: *const Mime) [:0]const u8 {
    const got = self.mime_types.items;

    for (got) |mt| {
        if (std.mem.eql(u8, mt, "text/plain")) {
            return mt;
        }

        std.log.debug("choose: {s}", .{mt});
    }

    // This should not be invalidated since choose is called after building the list.
    // For now return anything.
    return got[0];
}

pub fn deinit(self: *Mime, alloc: Allocator) void {
    self.mime_types.deinit(alloc);
}

/// Used to deduplicate useless other MIME types if they are referring to text/plain,
/// with or without UTF-8 encoding specified.
fn isPlainText(mime_type: [:0]const u8) bool {
    for (text_types) |tt| {
        if (std.mem.eql(u8, mime_type, tt)) return true;
    }

    return false;
}

pub fn append(self: *Mime, alloc: Allocator, mime_type: [:0]const u8) !void {
    if (self.mime_types.items.len >= 1 and self.got_plain_text and isPlainText(mime_type)) return;

    try self.mime_types.append(alloc, mime_type);
}
