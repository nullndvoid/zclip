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

//! Wayland interface for clipboard management. Call init before you do anything else.

const std = @import("std");
const Io = std.Io;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const Registry = wl.Registry;
const Event = Registry.Event;
const Display = wl.Display;
const Seat = wl.Seat;

const ext = @import("protocols/ext.zig");
const zwlr = @import("protocols/zwlr.zig");

const WaylandBackend = @This();

display: *Display,
registry: *Registry,
dcm: DataControlManager,
seat: *Seat,
io: Io,
dev: DataControlDevice,

const Globals = struct {
    ext_dcm: ?*ext.Manager = null,
    zwlr_dcm: ?*zwlr.Manager = null,
    seat: ?*Seat = null,
};

var globals: Globals = .{};

const DataControlManager = union(enum) {
    ext: *ext.Manager,
    zwlr: *zwlr.Manager,
};

const DataControlSource = union(enum) {
    ext: *ext.Source,
    zwlr: *zwlr.Source,
};

const DataControlDevice = union(enum) {
    ext: *ext.Device,
    zwlr: *zwlr.Device,
};

fn regListener(reg: *Registry, ev: Event, userdata: *Globals) void {
    switch (ev) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, ext.Manager.interface.name) == .eq) {
                userdata.ext_dcm = reg.bind(global.name, ext.Manager, 1) catch return;
                std.log.debug("Bound ExtDataControlManager V1 to globals.", .{});
            } else if (std.mem.orderZ(u8, global.interface, zwlr.Manager.interface.name) == .eq) {
                userdata.zwlr_dcm = reg.bind(global.name, zwlr.Manager, 1) catch return;
                std.log.debug("Bound ZwlrDataControlManager V1 to globals.", .{});
            } else if (std.mem.orderZ(u8, global.interface, Seat.interface.name) == .eq) {
                userdata.seat = reg.bind(global.name, Seat, 1) catch return;
                std.log.debug("Got wl_seat from compositor.", .{});
            }
        },
        .global_remove => {},
    }
}

pub fn init(io: Io) !WaylandBackend {
    var backend = try _init(io);
    backend.setDataDeviceListener();

    return backend;
}

/// This handles initialising most of the state we need but call `init` to handle setting up some event listeners for you.
fn _init(io: Io) !WaylandBackend {
    const display = try Display.connect(null);
    const registry = try display.getRegistry();

    registry.setListener(*Globals, regListener, &globals);
    const res = display.roundtrip();

    if (res != .SUCCESS) {
        return error.RoundTripFailed;
    }

    var dcm: ?DataControlManager = null;

    if (globals.ext_dcm) |ext_mgr| {
        dcm = .{ .ext = ext_mgr };
    } else if (globals.zwlr_dcm) |zwlr_mgr| {
        dcm = .{ .zwlr = zwlr_mgr };
    }

    const seat = globals.seat.?;
    const data_dev = try getDataDevice(dcm.?, seat);

    return .{
        .display = display,
        .registry = registry,
        .dcm = dcm.?,
        .seat = seat,
        .io = io,
        .dev = data_dev,
    };
}

pub fn deinit(self: WaylandBackend) void {
    if (globals.ext_dcm) |ext_mgr| {
        ext_mgr.destroy();
    }

    if (globals.zwlr_dcm) |zwlr_mgr| {
        zwlr_mgr.destroy();
    }

    self.registry.destroy();
    self.display.disconnect();
}

fn createDataSource(self: *WaylandBackend) !DataControlSource {
    return switch (self.dcm) {
        .ext => .{ .ext = try self.dcm.ext.createDataSource() },
        .zwlr => .{ .zwlr = try self.dcm.zwlr.createDataSource() },
    };
}

fn getDataDevice(dcm: DataControlManager, seat: *Seat) !DataControlDevice {
    return switch (dcm) {
        .ext => .{ .ext = try dcm.ext.getDataDevice(seat) },
        .zwlr => .{ .zwlr = try dcm.zwlr.getDataDevice(seat) },
    };
}

fn setDataDeviceListener(self: *WaylandBackend) void {
    switch (self.dev) {
        .ext => self.dev.ext.setListener(*WaylandBackend, ext.dataControlDeviceListener, self),
        .zwlr => self.dev.zwlr.setListener(*WaylandBackend, zwlr.dataControlDeviceListener, self),
    }
}

test "init and clean up" {
    const io = std.testing.io;
    const wayland_backend = try init(io);
    defer wayland_backend.deinit();

    // TODO: End-to-end test by pushing and pulling from clipboard,
    //       for now I am happy if we see some text.
    try io.sleep(.fromSeconds(5), .real);
}
