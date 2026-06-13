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

//! A library for management of the system clipboard, as well as
//! networking routines for usage in my consuming apps.

const std = @import("std");
const Io = std.Io;

const opts = @import("options");

pub const Backend = switch (opts.platform) {
    // TODO: Select X11/Wayland at runtime.
    .wayland => @import("Wayland.zig"),
    .windows => @import("Windows.zig"),
};

test {
    std.testing.refAllDecls(@This());
}
