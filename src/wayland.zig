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
const ExtDataControlManagerV1 = wayland.client.ext.DataControlManagerV1;
const ZwlrDataControlManagerV1 = wayland.client.zwlr.DataControlManagerV1;

const WaylandBackend = @This();

display: *Display,
registry: *Registry,
dcm: DataControlManager,

const Globals = struct {
    ext_dcm: ?*ExtDataControlManagerV1 = null,
    zlwr_dcm: ?*ZwlrDataControlManagerV1 = null,
};

var globals: Globals = .{};

// We want to only use one of these in practice. Prefer the Ext standard version
// since the Wlr one is deprecated.
const DataControlManager = union(enum) {
    ext: *ExtDataControlManagerV1,
    zwlr: *ZwlrDataControlManagerV1,
};

const DataControlSource = union(enum) {
    ext: *wayland.client.ext.DataControlSourceV1,
    zwlr: *wayland.client.zwlr.DataControlSourceV1,
};

fn regListener(reg: *Registry, ev: Event, userdata: *Globals) void {
    switch (ev) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, ExtDataControlManagerV1.interface.name) == .eq) {
                userdata.ext_dcm = reg.bind(global.name, ExtDataControlManagerV1, 1) catch return;
                std.log.debug("Bound ExtDataControlManager V1 to globals.", .{});
            } else if (std.mem.orderZ(u8, global.interface, ZwlrDataControlManagerV1.interface.name) == .eq) {
                userdata.zlwr_dcm = reg.bind(global.name, ZwlrDataControlManagerV1, 1) catch return;
                std.log.debug("Bound ZwlrDataControlManager V1 to globals.", .{});
            }
        },
        // TODO: Maybe handle this but I think it's not majorly important.
        .global_remove => {
            // std.log.debug("Got .global_remove event this is unhandled! {}", .{ev});
        },
    }
}

/// Should be called before attempting to call any of the other
/// functions in this file.
pub fn init() !WaylandBackend {
    const display = try Display.connect(null);
    const registry = try display.getRegistry();

    registry.setListener(*Globals, regListener, &globals);
    const res = display.roundtrip();

    if (res != .SUCCESS) {
        // std.log.err("Display roundtrip failed: {}", res);
        return error.RoundTripFailed;
    }

    // We want to default to the Ext version.
    var dcm: ?DataControlManager = null;

    if (globals.ext_dcm) |ext| {
        dcm = .{ .ext = ext };
    }

    blk: {
        if (globals.zlwr_dcm) |zwlr| {
            if (dcm) |_| {
                break :blk;
            }

            dcm = .{ .zwlr = zwlr };
        }
    }

    return .{
        .display = display,
        .registry = registry,
        .dcm = dcm.?,
    };
}

pub fn deinit(self: WaylandBackend) void {
    if (globals.ext_dcm) |ext| {
        ext.destroy();
    }

    if (globals.zlwr_dcm) |zwlr| {
        zwlr.destroy();
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

pub fn getClipboard(self: *WaylandBackend) !void {
    _ = self; // autofix

}

test "init and clean up" {
    const wayland_backend = try init();
    defer wayland_backend.deinit();
}
