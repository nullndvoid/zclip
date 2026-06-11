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

const State = struct {
    pending_offer: ?*Offer = null,
    current_offer: ?*Offer = null,
};

var state: State = .{};

pub fn dataControlOfferListener(_: *Offer, ev: Offer.Event, _: *Parent) void {
    std.log.debug("Got MIME type: {s}", .{ev.offer.mime_type});
}

pub fn dataControlDeviceListener(dev: *Device, ev: Device.Event, parent: *Parent) void {
    _ = dev;
    switch (ev) {
        .data_offer => |offer_ev| {
            state.pending_offer = offer_ev.id;
            offer_ev.id.setListener(*Parent, dataControlOfferListener, parent);
        },
        .selection => |sel_ev| {
            state.current_offer = sel_ev.id;
            readOffer(parent, sel_ev.id orelse return);
        },
        .primary_selection => |prim_ev| {
            readOffer(parent, prim_ev.id orelse return);
        },
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
fn readOffer(parent: *Parent, offer: *Offer) void {
    const io = parent.io;

    var pipe: [2]i32 = undefined;
    if (std.c.pipe(&pipe) != 0) {
        std.log.err("Could not create pipe!", .{});
        c.perror(null);
        return;
    }

    offer.receive("text/plain", pipe[1]);
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

    const bytes = rdr.allocRemaining(parent.alloc, .unlimited) catch return;
    defer parent.alloc.free(bytes);

    std.log.debug("Clipboard: {s}", .{bytes});
}
