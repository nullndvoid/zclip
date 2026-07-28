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

//! A writer that encrypts its inputs and forwards them onto a sink.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;

const NoiseSession = @import("NoiseSession.zig");

interface: Writer,
session: *NoiseSession,
/// Writes to the socket or wherever.
sink: *Writer,
err: ?anyerror = null,

const vtable = Writer.VTable{
    .drain = Writer.fixedDrain,
    .flush = flush,
    .rebase = Writer.failingRebase,
};

pub fn init(session: *NoiseSession, writer: *Writer) EncryptedWriter {
    const buf = session.write_buf[2 .. session.write_buf.len - NoiseSession.AEAD_TAG_LENGTH];
    std.debug.assert(buf.len == session.maxPayloadLength());

    return .{
        .session = session,
        // This way we can write directly to the write_buf and on flush we can
        // emit length prefix etc.
        .interface = initInterface(buf),
        .sink = writer,
    };
}

fn initInterface(buf: []u8) Writer {
    return .{
        .buffer = buf,
        .vtable = &vtable,
    };
}

const EncryptedWriter = @This();

/// You should not retry a flush or write if this fails, since the buffer is
/// already clobbered.
fn flush(w: *Writer) Writer.Error!void {
    const self: *EncryptedWriter = @alignCast(@fieldParentPtr("interface", w));
    if (w.end == 0) return;

    self.session.sendBuffered(self.sink, w.end) catch |err| {
        self.err = err;
        return error.WriteFailed;
    };

    w.end = 0;
}
