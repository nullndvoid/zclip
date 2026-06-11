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

//! MIME type selection helpers, mirroring wl-clipboard's behaviour.
//! TODO: Handle images and stuff set to text/html. We can parse out
//!       the image extension and use this to get the correct MIME type
//!       -- this will need us to store a list of fallbacks i.e. image/, audio/,
//!          and send another request to the compositor.

const std = @import("std");

/// Longest MIME type string we will remember for a single offer. Real types are
/// far shorter; anything longer is ignored rather than stored.
pub const max_len = 255;

/// Mirrors wl-clipboard's `mime_type_is_text` (src/util/string.c).
pub fn isText(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, "text/") or
        std.mem.eql(u8, mime, "TEXT") or
        std.mem.eql(u8, mime, "STRING") or
        std.mem.eql(u8, mime, "UTF8_STRING") or
        std.mem.indexOf(u8, mime, "json") != null or
        std.mem.endsWith(u8, mime, "script") or
        std.mem.endsWith(u8, mime, "xml") or
        std.mem.endsWith(u8, mime, "yaml") or
        std.mem.endsWith(u8, mime, "csv") or
        std.mem.endsWith(u8, mime, "ini") or
        std.mem.indexOf(u8, mime, "application/vnd.ms-publisher") != null or
        std.mem.endsWith(u8, mime, "pgp-keys");
}

/// Preference score for an offered MIME type, following wl-clipboard's
/// `mime_type_to_request` order when no type is inferred: UTF-8 text is best,
/// then text/plain, then any text type, then anything at all. The score-1
/// fallback is what captures a pure image (or other binary) copy that offers no
/// text representation. Higher is more preferred; never returns 0.
pub fn score(mime: []const u8) u8 {
    if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return 4;
    if (std.mem.eql(u8, mime, "text/plain")) return 3;
    if (isText(mime)) return 2;
    return 1;
}
