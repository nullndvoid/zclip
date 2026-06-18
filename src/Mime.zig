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

allocator: Allocator,

pub fn init(alloc: Allocator, max_capacity: usize) !Mime {
    return .{
        .allocator = alloc,
        .mime_types = try .initCapacity(alloc, max_capacity),
    };
}

/// Called on reciept of new set of MIME types.
pub fn reset(self: *Mime) void {
    self.mime_types.clearRetainingCapacity();
    self.got_plain_text = false;
}

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
pub fn choose(self: *const Mime) ?[:0]const u8 {
    for (self.mime_types.items) |it| {
        std.log.debug("In list: {s}", .{it});
    }

    // This should not be invalidated since choose is called after building the list.
    // For now return anything.
    return null;
}

pub fn deinit(self: *Mime) void {
    self.mime_types.deinit(self.allocator);
}

/// Used to deduplicate useless other MIME types if they are referring to text/plain,
/// with or without UTF-8 encoding specified.
///
/// Returns true if the `mime_type` matches a known plaintext type.
///
/// TODO: Make a proper helper for use when setting Clip.is_text, because HTML is plain text,
///       as is application/json etc.
pub fn isPlainText(mime_type: [:0]const u8) bool {
    for (text_types) |tt| {
        if (std.mem.orderZ(u8, mime_type, tt) == .eq) {
            return true;
        }
    }

    return false;
}

pub fn append(self: *Mime, mime_type: [:0]const u8) !void {
    if (self.mime_types.items.len == self.mime_types.capacity) return error.AtCapacity;

    const is_plain = isPlainText(mime_type);
    if (self.got_plain_text and is_plain) return;

    self.mime_types.appendAssumeCapacity(mime_type);
    if (is_plain) self.got_plain_text = true;
}
