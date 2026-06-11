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

const WaylandBackend = @This();

display: *wl.Display,
registry: *wl.Registry,

const Globals = struct {};

/// Should be called before attempting to call any of the other
/// functions in this file.
pub fn init() !WaylandBackend {
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    // registry.setListener(*Globals, regListener, _data: T)

    return .{
        .display = display,
        .registry = registry,
    };
}

pub fn deinit(self: WaylandBackend) void {
    self.registry.destroy();
    self.display.disconnect();
}

pub fn getClipboard(self: *WaylandBackend) !void {
    _ = self; // autofix
}
