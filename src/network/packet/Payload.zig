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

//! Packet payload definitions.

const clipboard = @import("clipboard");

const Packet = @import("../Packet.zig");
const Id = Packet.Id;

pub const Tag = enum(u8) {
    clip = 0,
    request_formats = 1,
    formats_response = 2,
    request_clip = 3,
    request_clip_response = 4,
    ok_response = 5,
    shutting_down = 6,
    err = 7,
    _,
};

/// If new commands are added in later versions, I shall prefix them with vN.
pub const Payload = union(Tag) {
    /// A clipboard entry with default MIME type.
    clip: Clip,
    /// Requests a list of formats for a clip of `id`.
    request_formats: Id,
    /// A list of formats for a clip of `id`.
    formats_response: FormatsResponse,
    /// A peer requests a clip of `id` and `format`.
    request_clip: RequestClip,
    /// This may be packetised, so there will be a seq of chunks.
    /// Last chunk may not occupy the total payload space.
    request_clip_response: RequestClipResponse,
    /// Sent back when the last operation completed successfully,
    /// but nothing need be returned.
    ///
    /// Contains the request ID of the relevant request.
    ///
    /// No one is actually expected to track more than the last one or
    /// two requests to check this is __actually__ unique.
    ///
    /// This is also sent when events like `clip` are sent as a ping/pong
    /// type of deal. Maybe this can be used for some kind of keepalive?
    ok_response: Id,
    /// Sent when the peer is shutting down, so all connected peers know to
    /// terminate their connections.
    shutting_down,
    /// Sent on errors.
    err: Error,

    pub const Clip = struct {
        /// Used to track the clip on that particular server.
        id: Id,
        mime_type: []const u8,
        chunk: Chunk,
    };

    pub const FormatsResponse = struct {
        id: Id,
        formats: []ClipFormat,
    };

    pub const RequestClip = struct {
        id: Id,
        format: ClipFormat,
    };

    pub const RequestClipResponse = struct {
        id: Id,
        format: ClipFormat,
        chunk: Chunk,
    };

    pub const Error = struct {
        tag: ErrorTags,
        /// For debugging purposes. May be displayed to the user.
        ///
        /// This will be displayed alongside the default message if present.
        extra_context: ?[]const u8 = null,
    };
};

/// Returns the friendlier error message given an error.
pub fn errorMessage(err: ErrorTags) []const u8 {
    return switch (err) {
        .NoSuchId => "An ID was supplied in a request but did not exist.",
        .PeerRemoved => "The connected peer removed this one.",
        else => "Invalid error tag set.",
    };
}

/// These are errors that can be returned across peer boundaries.
///
/// Although encoded as u8, the top bit is out of use as it is
/// used to check for the optional message included with an error.
pub const ErrorTags = enum(u8) {
    /// An ID was supplied in a request but did not exist.
    NoSuchId = 0,
    /// Sent when we no longer want this peer trying to connect, e.g. we
    /// removed them, or the handshake succeeded but we don't recognize
    /// their pubkey. Receiver should mark us degraded and stop retrying
    /// until cleared.
    PeerRemoved = 1,
    _,
};

comptime {
    for (@typeInfo(ErrorTags).@"enum".field_values) |fv| {
        if (fv > 127) @compileError("Top error tag bit is reserved!");
    }
}

/// A chunk in messages which may be packetised.
pub const Chunk = struct {
    seq: u32,
    end: u32,
    bytes: []const u8,
};

// Comptime check that Chunk fields are last. This encourages people to read and
// write chunks last in the below serialisation/deser code.
comptime {
    const union_info = @typeInfo(Payload).@"union";
    for (union_info.field_names, union_info.field_types) |un, ut| {
        const ti = @typeInfo(ut);
        if (ti != .@"struct") continue;
        const fields = ti.@"struct".field_types;
        for (fields, 0..) |ft, i| {
            if (ft == Chunk and i != fields.len - 1)
                @compileError("Chunk must be the last field of Payload." ++ un);
        }
    }
}

/// Reproduced from my clipboard-zig library because I want to roll my own
/// ser/deser.
pub const ClipType = enum(u8) {
    text = 0,
    html = 1,
    image = 2,
    file = 3,
    rtf = 4,
    other = 5,
    _,
};

/// Reproduced from my clipboard-zig library because I want to roll my own
/// ser/deser.
pub const ClipFormat = struct {
    fmt: ClipType,
    mime: []const u8,

    pub fn from(fmt: clipboard.Clip.Format) ClipFormat {
        const clip_type: ClipType = switch (fmt.format) {
            .text => .text,
            .html => .html,
            .rtf => .rtf,
            .image => .image,
            .file => .file,
            .other => .other,
        };

        return .{
            .fmt = clip_type,
            .mime = fmt.mime_type,
        };
    }
};
