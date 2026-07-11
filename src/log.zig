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

//! Logging, allowing debug logs in Release builds.

const std = @import("std");
const builtin = @import("builtin");

/// Runtime log level.
pub var level: std.log.Level = if (builtin.mode == .Debug) .debug else .info;

/// Installed as `std.Options.logFn`.
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(level)) return;
    std.log.defaultLog(message_level, scope, format, args);
}
