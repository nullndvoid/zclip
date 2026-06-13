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
const Io = std.Io;

const c = @import("c");
const wayland = @import("wayland");
const wl = wayland.client.wl;
pub const Manager = wayland.client.ext.DataControlManagerV1;
pub const Device = wayland.client.ext.DataControlDeviceV1;
pub const Source = wayland.client.ext.DataControlSourceV1;
pub const Offer = wayland.client.ext.DataControlOfferV1;

const Parent = @import("../wayland.zig");
const mimes = @import("mime.zig");

const State = struct {
    pending_offer: ?*Offer = null,
    current_offer: ?*Offer = null,
    best_score: u8 = 0,
    best_mime: [mimes.max_len:0]u8 = @splat(0),
    best_mime_len: usize = 0,
};

var state: State = .{};

pub fn dataControlOfferListener(_: *Offer, ev: Offer.Event, _: *Parent) void {
    const mime = std.mem.span(ev.offer.mime_type);
    const new_score = mimes.score(mime);
    // Keep the first-seen MIME type within a tier.
    if (new_score <= state.best_score or mime.len > mimes.max_len) return;

    @memcpy(state.best_mime[0..mime.len], mime);
    state.best_mime[mime.len] = 0;
    state.best_mime_len = mime.len;
    state.best_score = new_score;
}

pub fn dataControlDeviceListener(dev: *Device, ev: Device.Event, parent: *Parent) void {
    _ = dev;
    switch (ev) {
        .data_offer => |offer_ev| {
            state.pending_offer = offer_ev.id;
            // Start scoring this offer's MIME types from scratch.
            state.best_score = 0;
            state.best_mime_len = 0;
            offer_ev.id.setListener(*Parent, dataControlOfferListener, parent);
        },
        .selection => |sel_ev| {
            const offer = sel_ev.id orelse return;
            state.current_offer = offer;
            if (state.best_score == 0) {
                std.log.debug("Clipboard offer advertised no usable MIME type.", .{});
                return;
            }
            readOffer(parent, offer, state.best_mime[0..state.best_mime_len :0]);
        },
        // The primary selection changes whenever text is merely highlighted
        // (for middle-click paste). We only care about the clipboard, i.e.
        // explicit copies, so ignore it.
        .primary_selection => {},
        .finished => {
            if (state.current_offer) |offer| {
                offer.destroy();
            }
        },
    }
}

/// # Request that the data is transferred
/// To transfer the offered data, the client issues this request and indicates the MIME type it wants to receive. The transfer happens through the passed file descriptor (typically created with the pipe system call). The source client writes the data in the MIME type representation requested and then closes the file descriptor.
/// The receiving client reads from the read end of the pipe until EOF and then closes its end, at which point the transfer is complete.
fn readOffer(parent: *Parent, offer: *Offer, mime_type: [:0]const u8) void {
    const io = parent.io;

    var pipe: [2]i32 = undefined;
    if (std.c.pipe(&pipe) != 0) {
        std.log.err("Could not create pipe!", .{});
        c.perror(null);
        return;
    }

    offer.receive(mime_type, pipe[1]);
    _ = std.c.close(pipe[1]);

    // Don't forget to flush...
    if (parent.display.flush() != .SUCCESS) {
        std.log.err("Failed to flush display for clipboard receive.", .{});
        _ = std.c.close(pipe[0]);
        return;
    }

    const read_file = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = false } };
    defer read_file.close(io);

    var rdr_buf: [4096]u8 = undefined;

    var file_rdr = read_file.reader(io, &rdr_buf);
    const rdr = &file_rdr.interface;

    // Remembering parent.alloc is wrapped in an arena, don't bother freeing here.
    const bytes = rdr.allocRemaining(parent.alloc, .unlimited) catch return;

    if (mimes.isText(mime_type)) {
        std.log.debug("Clipboard [{s}]: {s}", .{ mime_type, bytes });
    } else {
        std.log.debug("Clipboard [{s}]: {d} bytes", .{ mime_type, bytes.len });
    }

    const mime_type_duped = parent.alloc.dupe(u8, mime_type) catch return;

    parent.read_queue.putOne(parent.io, .{
        .data = bytes,
        .mime_type = mime_type_duped,
        .node = .{},
    }) catch return;
}
