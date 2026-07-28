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
const assert = std.debug.assert;

const clipboard = @import("clipboard");
const Serde = @import("serde");

const Header = @import("packet/Header.zig");
const p = @import("packet/Payload.zig");
const Payload = p.Payload;
const PayloadTag = p.Tag;
const Chunk = p.Chunk;
const ClipFormat = p.ClipFormat;
const ClipType = p.ClipType;
const ErrorTags = p.ErrorTags;

const Packet = @This();

pub const Id = u64;

const ID_LEN = @sizeOf(Id);
const TAG_LEN = @sizeOf(u8);
const SLICE_PREFIX_LEN = @sizeOf(u32);
const HEADER_LEN = ID_LEN + @sizeOf(i64) + TAG_LEN;
/// Used for short prefixed lengths where we are not ever going to have >255
/// elements.
const SHORT_PREFIX_LEN = @sizeOf(u8);

header: Header,
payload: Payload,

pub const serde = .{
    .flatten = &[_][]const u8{"header"},
};

/// Creates a packet with a timestamp.
pub fn init(io: Io, id: Id, payload: Payload) Packet {
    const time_now = Io.Timestamp.now(io, .real);

    return .{
        .header = .{
            .request_id = id,
            .timestamp_ms = .{ .val = time_now.toMilliseconds() },
        },
        .payload = payload,
    };
}

pub fn format(
    self: Packet,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    Serde.json.toPrettyWriter(writer, self, .{}) catch unreachable;
}

/// All integer values are sent in big endian network order.
///
/// Packets are assumed to be of the correct size, so we can
/// have a buffer allocated only once (per peer), which can
/// be used for all packets sent and recieved.
pub fn encode(packet: *const Packet, writer: *Io.Writer) !void {
    // Write the request id, timestamp, and tag.
    try writer.writeInt(u8, @intFromEnum(packet.payload), .big);
    try writer.writeInt(Id, packet.header.request_id, .big);
    try writer.writeInt(i64, packet.header.timestamp_ms.val, .big);

    switch (packet.payload) {
        .request_formats, .ok_response => |id| try writer.writeInt(Id, id, .big),
        .shutting_down => {},
        .err => |err| {
            // We set the upper bit to determine if there was an optional message.
            const opt = @as(u8, @intCast(@intFromBool(err.extra_context != null))) << 7;
            const tag: u8 = @intFromEnum(err.tag) | opt;

            try writer.writeInt(u8, tag, .big);

            if (err.extra_context) |ctx| {
                try writer.writeAll(ctx);
            }
        },
        .clip => |clip| {
            try writer.writeInt(Id, clip.id, .big);
            try writeByteSlice(writer, clip.mime_type);
            try writeChunk(writer, clip.chunk);
        },
        .request_clip => |rc| {
            try writer.writeInt(Id, rc.id, .big);
            try writeClipFormat(writer, rc.format);
        },
        .formats_response => |fmts| {
            try writer.writeInt(Id, fmts.id, .big);
            // This limit is essentially unreachable.
            assert(fmts.formats.len <= std.math.maxInt(u8));

            try writer.writeInt(u8, @intCast(fmts.formats.len), .big);
            for (fmts.formats) |fmt| {
                try writeClipFormat(writer, fmt);
            }
        },
        .request_clip_response => |clip| {
            try writer.writeInt(Id, clip.id, .big);
            try writeClipFormat(writer, clip.format);
            try writeChunk(writer, clip.chunk);
        },
    }
}

pub fn decode(buf: []const u8) !Packet {
    var out: Packet = undefined;
    // This should track cursor position for us, so we should be able
    // to slice from current position and skip ahead.
    var rdr = Io.Reader.fixed(buf);

    const payload_tag: PayloadTag = @enumFromInt(try rdr.takeInt(u8, .big));
    const request_id = try rdr.takeInt(Id, .big);
    const timestamp_ms = try rdr.takeInt(i64, .big);

    out.header = .{
        .request_id = request_id,
        .timestamp_ms = .{ .val = timestamp_ms },
    };

    switch (payload_tag) {
        .clip => {
            const id = try rdr.takeInt(Id, .big);
            const mime = try readByteSlice(&rdr);
            const chunk = try readChunkAssumeLast(&rdr);

            out.payload = .{
                .clip = .{
                    .id = id,
                    .mime_type = mime,
                    .chunk = chunk,
                },
            };
        },
        .err => {
            const tag = try rdr.takeInt(u8, .big);
            const err_tag, const take_slice = decodeErrTag(tag);

            const ctx = if (take_slice) rdr.buffered() else null;

            if (ctx == null and rdr.bufferedLen() != 0) return error.ExtraJunk;

            out.payload = .{
                .err = .{
                    .tag = err_tag,
                    .extra_context = ctx,
                },
            };
        },
        .formats_response => {},
        .ok_response => {
            const id = try rdr.takeInt(Id, .big);
            out.payload = .{ .ok_response = id };
        },
        .shutting_down => {
            out.payload = .shutting_down;
        },
        .request_clip => {
            const id = try rdr.takeInt(Id, .big);
            const fmt = try readClipFormat(&rdr);

            out.payload = .{
                .request_clip = .{
                    .id = id,
                    .format = fmt,
                },
            };
        },
        .request_clip_response => {
            const id = try rdr.takeInt(Id, .big);
            const fmt = try readClipFormat(&rdr);
            const chunk = try readChunkAssumeLast(&rdr);

            out.payload = .{
                .request_clip_response = .{
                    .id = id,
                    .format = fmt,
                    .chunk = chunk,
                },
            };
        },
        .request_formats => {
            const id = try rdr.takeInt(Id, .big);
            out.payload = .{ .request_formats = id };
        },
        _ => return error.InvalidPayload,
    }

    return out;
}

/// Returns the on wire (serialised) size of a packet.
///
/// encodedSize(.{}) + body.len (i.e. chunk len) = encodedSize(packet_with_body)
/// so this may be called once and memoised when writing several chunks etc.
///
/// This invariant may be broken when adding new fields, so take care.
pub fn encodedSize(packet: *const Packet) usize {
    return HEADER_LEN + switch (packet.payload) {
        .clip => |clip| SLICE_PREFIX_LEN + clip.mime_type.len + ID_LEN + chunkSize(clip.chunk),
        .err => |err| TAG_LEN + if (err.extra_context) |ctx| ctx.len else 0,
        .request_formats, .ok_response => ID_LEN,
        .shutting_down => 0,
        .request_clip_response => |clip| ID_LEN + chunkSize(clip.chunk) + TAG_LEN + SLICE_PREFIX_LEN + clip.format.mime.len,
        // 1 byte length prefix is certainly fine.
        .formats_response => |fmts| ID_LEN + blk: {
            var overhead: usize = SHORT_PREFIX_LEN;
            for (fmts.formats) |fmt| {
                overhead += TAG_LEN + SLICE_PREFIX_LEN + fmt.mime.len;
            }

            break :blk overhead;
        },
        .request_clip => |req| ID_LEN + TAG_LEN + SLICE_PREFIX_LEN + req.format.mime.len,
    };
}

fn chunkSize(chunk: Chunk) usize {
    return chunk.bytes.len +
        @sizeOf(@TypeOf(chunk.end)) +
        @sizeOf(@TypeOf(chunk.seq));
}

inline fn writeClipFormat(writer: *Io.Writer, fmt: ClipFormat) !void {
    try writer.writeInt(u8, @intFromEnum(fmt.fmt), .big);
    try writeByteSlice(writer, fmt.mime);
}

inline fn readClipFormat(rdr: *Io.Reader) !ClipFormat {
    const clip_type: ClipType = @enumFromInt(try rdr.takeInt(u8, .big));
    switch (clip_type) {
        .file, .html, .image, .other, .rtf, .text => {},
        _ => return error.InvalidClipType,
    }

    const mime = try readByteSlice(rdr);

    return .{
        .fmt = clip_type,
        .mime = mime,
    };
}

/// Even a u32 is overkill but its alright for now.
inline fn writeByteSlice(writer: *Io.Writer, bytes: []const u8) !void {
    assert(bytes.len <= std.math.maxInt(u32));

    try writer.writeInt(u32, @intCast(bytes.len), .big);
    try writer.writeAll(bytes);
}

inline fn readByteSlice(rdr: *Io.Reader) ![]const u8 {
    const len = try rdr.takeInt(u32, .big);
    if (len > rdr.bufferedLen()) return error.InvalidSliceLen;

    return try rdr.take(len);
}

/// This assumes chunks are written last so we know how many bytes to read.
inline fn writeChunk(writer: *Io.Writer, chunk: Chunk) !void {
    try writer.writeInt(u32, chunk.seq, .big);
    try writer.writeInt(u32, chunk.end, .big);
    try writer.writeAll(chunk.bytes);
}

inline fn readChunkAssumeLast(rdr: *Io.Reader) !Chunk {
    const seq = try rdr.takeInt(u32, .big);
    const end = try rdr.takeInt(u32, .big);
    const bytes = try rdr.take(rdr.bufferedLen());

    return .{
        .seq = seq,
        .end = end,
        .bytes = bytes,
    };
}

/// Returns (tag, should_read_slice).
inline fn decodeErrTag(err_tag: u8) struct { ErrorTags, bool } {
    const tag: ErrorTags = @enumFromInt(err_tag & 0x7f);
    const should_read_slice: bool = (err_tag & 0x80) != 0;

    return .{ tag, should_read_slice };
}

/// Just used for regression testing of encodedSize.
fn checkEncodedSizeEqlsWritten(packet: *const Packet) !void {
    const t = std.testing;

    var discarding = Io.Writer.Discarding.init(&.{});
    const writer = &discarding.writer;

    try packet.encode(writer);

    try t.expectEqual(discarding.fullCount(), packet.encodedSize());
}

test "encodedSize with no body" {
    const t = std.testing;

    const packet = init(t.io, 1234, .shutting_down);

    try checkEncodedSizeEqlsWritten(&packet);
}

test "encodedSize with .clip" {
    const t = std.testing;

    const packet = init(t.io, 5678, .{
        .clip = .{
            .id = 123,
            .mime_type = "text/plain;charset=utf-8",
            .chunk = .{
                .seq = 0,
                .end = 0,
                .bytes = "Hello, world!",
            },
        },
    });

    try checkEncodedSizeEqlsWritten(&packet);
}

fn encodeDecodeParity(packet: *const Packet, alloc: std.mem.Allocator) !void {
    const t = std.testing;

    var allocating = Io.Writer.Allocating.init(alloc);
    const writer = &allocating.writer;
    errdefer allocating.deinit();

    try packet.encode(writer);

    const bytes = try allocating.toOwnedSlice();
    defer alloc.free(bytes);

    const decoded = try decode(bytes);

    try t.expectEqualDeep(packet, &decoded);
}

test "encode and decode clip packet" {
    const t = std.testing;

    const packet = init(t.io, 5678, .{
        .clip = .{
            .id = 123,
            .mime_type = "text/plain;charset=utf-8",
            .chunk = .{
                .seq = 0,
                .end = 0,
                .bytes = "Hello, world!",
            },
        },
    });

    try encodeDecodeParity(&packet, t.allocator);
}

test "encode and decode blank packet" {
    const t = std.testing;

    const packet = init(t.io, 1234, .shutting_down);

    try encodeDecodeParity(&packet, t.allocator);
}

test "decode err with junk data" {
    const t = std.testing;

    const id: Id = 3817;
    var id_buf: [8]u8 = undefined;
    std.mem.writeInt(Id, &id_buf, id, .big);

    const timestamp_ms: i64 = 1785258230475;
    var timestamp_ms_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &timestamp_ms_buf, timestamp_ms, .big);

    const payload_tag: []const u8 = &.{@intFromEnum(PayloadTag.err)};

    // No upper bit set so we expect no data after the tag.
    const error_tag: []const u8 = &.{@intFromEnum(ErrorTags.NoSuchId)};

    // Finally if we append some junk data after an error tag with null
    // extra_context we should get an error.
    const packet_bytes: []const u8 = payload_tag ++ &id_buf ++
        &timestamp_ms_buf ++ error_tag ++ &[_]u8{ 0x67, 0x41 };

    try t.expectError(error.ExtraJunk, decode(packet_bytes));
}

test "reject unknown payload type" {
    const t = std.testing;
    const alloc = t.allocator;

    const packet = init(t.io, 1234, .shutting_down);

    var allocating = Io.Writer.Allocating.init(alloc);
    const writer = &allocating.writer;
    errdefer allocating.deinit();

    try packet.encode(writer);

    var bytes = try allocating.toOwnedSlice();
    defer alloc.free(bytes);

    // First byte is for the payload.
    bytes[0] = 0xAA;

    try t.expectError(error.InvalidPayload, decode(bytes));
}
