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
const Io  = std.Io;
const Allocator = std.mem.Allocator;

const wayland = @import("wayland").client;
const wl = wayland.wl;
const Display = wl.Display;
const Registry = wl.Registry;
const Seat = wl.Seat;

const Wayland = @This();

alloc: Allocator,

display: *Display,
registry: *Registry,
seat: *Seat,
dcm: DataControlManager,
dev: DataControlDevice,

/// Stored for later deallocation.
listener_ctx: *ListenerContext,

// Passed into DataControlDevice listeners.
const ListenerContext = struct {
    alloc: Allocator,
    io: Io,
};

pub fn init(io: Io, alloc: Allocator) !Wayland {
    const display = try Display.connect(null);
    var reg = try display.getRegistry();
    var globals = Globals{};

    reg.setListener(*Globals, registryListener, &globals);

    const ret = display.roundtrip();
    if (ret != .SUCCESS) return error.RoundtripFailed;

    // This might fire on compositors using old wlroots but I will not implement Zwlr support yet.
    if (globals.ext_dc_manager == null or globals.seat == null) return error.MissingGlobals;

    const seat = globals.seat.?;

    // TODO: Support deprecated zwlr_data_control_manager_v1.
    var dcm = DataControlManager{
        .Ext = globals.ext_dc_manager.?,
    };

    const dev = try dcm.getDataDevice(seat);

    var listener_ctx = try alloc.create(ListenerContext);
    listener_ctx.alloc = alloc;
    listener_ctx.io = io;

    switch (dev) {
        .Ext => |ext| {
            ext.setListener(*ListenerContext, Ext.listener, &listener_ctx);
        },
    }

    return .{
        .alloc = alloc,
        .display = display,
        .registry = reg,
        .seat = seat,
        .dcm = dcm,
        .dev = dev,
        .listener_ctx = listener_ctx,
    };
}

pub fn deinit(self: Wayland) void {
    self.dev.destroy();
    self.dcm.destroy();
    self.alloc.destroy(self.listener_ctx);

    self.registry.destroy();
    self.display.disconnect();
}

const DataControlDevice = union(enum) {
    Ext: *Ext.Device,

    pub inline fn destroy(self: DataControlDevice) void {
        switch (self) {
            .Ext => |dev| {
                dev.destroy();
            },
        }
    }
};

const DataControlSource = union(enum) {
    Ext: *Ext.Source,
};

const DataControlManager = union(enum) {
    Ext: *Ext.Manager,

    pub inline fn destroy(self: DataControlManager) void {
        switch (self) {
            .Ext => |mgr| {
                mgr.destroy();
            },
        }
    }

    pub inline fn getDataDevice(self: DataControlManager, seat: *Seat) !DataControlDevice {
        switch (self) {
            .Ext => |mgr| {
                const device = try mgr.getDataDevice(seat);
                return .{ .Ext = device };
            },
        }
    }

    pub inline fn createDataSource(self: DataControlManager) !DataControlSource {
        switch (self) {
            .Ext => |mgr| {
                const source = try mgr.createDataSource();
                return .{ .Ext = source };
            },
        }
    }
};

/// Used for `registryListener` when we need compositor globals.
const Globals = struct {
    ext_dc_manager: ?*Ext.Manager = null,
    seat: ?*Seat = null,
};

/// Handles the `ext_data_control` protocol. I will support deprecated zwlr
/// later if need be. Should contain event handlers.
const Ext = struct {
    pub const Manager = wayland.ext.DataControlManagerV1;
    pub const Device = wayland.ext.DataControlDeviceV1;
    pub const Source = wayland.ext.DataControlSourceV1;
    pub const Offer = wayland.ext.DataControlOfferV1;

    pub fn Listener() void {}
};

/// See doc comment on `Ext`. Not yet implemented.
const Zwlr = struct {};

fn registryListener(reg: *Registry, event: Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |ev| {
            if (std.mem.orderZ(u8, ev.interface, Ext.Manager.interface.name) == .eq) {
                globals.ext_dc_manager = reg.bind(ev.name, Ext.Manager, 1) catch return;
            } else if (std.mem.orderZ(u8, ev.interface, Seat.interface.name) == .eq) {
                globals.seat = reg.bind(ev.name, Seat, 1) catch return;
            } else return;

            std.log.debug("Compositor gave us global {s}", .{ev.interface});
        },
        .global_remove => {},
    }
}

test "init/deinit" {
    const backend = try Wayland.init();
    defer backend.deinit();
}
