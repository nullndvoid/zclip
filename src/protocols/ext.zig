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
            readOffer(parent.io, sel_ev.id orelse return);
        },
        .primary_selection => |prim_ev| {
            readOffer(parent.io, prim_ev.id orelse return);
        },
        .finished => {
            if (state.current_offer) |offer| {
                offer.destroy();
            }
        },
    }
}

fn readOffer(io: Io, offer: *Offer) void {
    var pipe: [2]i32 = undefined;
    if (std.c.pipe(&pipe) != 0) {
        std.log.err("Could not create pipe!", .{});
        c.perror(null);
    }

    // Otherwise:
    offer.receive("text/plain", pipe[1]);
    _ = std.c.close(pipe[1]);

    const read_file = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = false } };
    defer read_file.close(io);

    var rdr_buf: [4096]u8 = undefined;

    var file_rdr = read_file.reader(io, &rdr_buf);
    const rdr = &file_rdr.interface;

    // TODO: Read with allocation perhaps? Currently we truncate.
    var buf: [4096]u8 = @splat(0);
    var read: usize = 0;

    while (read < buf.len) {
        const got = rdr.readSliceShort(buf[read..]) catch return;
        if (got == 0) break;
        read += got;
    }

    std.log.debug("Clipboard: {s}\n", .{buf[0..read]});
}
