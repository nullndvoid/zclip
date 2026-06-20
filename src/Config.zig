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

//! Configuration for zclip.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const known = @import("known-folders");

const BACKEND_ALLOC_LIMIT_DEFAULT = 1024 * 1024 * 512;
const IS_DEBUG = @import("builtin").mode == .Debug;

const log = std.log.scoped(.config);

const Config = @This();

debugging: Debugging = .{},

/// Optional memory limit for the process excluding I/O (futures). More useful for Debugging.
const Debugging = struct {
    memory_limit: ?usize = if (IS_DEBUG) BACKEND_ALLOC_LIMIT_DEFAULT else null,
};

pub fn fromPath(io: Io, allocator: Allocator, absolute_path: []const u8) !Config {
    var config = Io.Dir.openFileAbsolute(io, absolute_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.err("Config file not found at {s}.", .{absolute_path});
            },
            else => {
                log.err("Could not open config file at {s}. Reason: {t}", .{ absolute_path, err });
            },
        }
        return err;
    };

    defer config.close(io);

    var read_buf: [1024]u8 = undefined;
    var file_rdr = config.reader(io, &read_buf);
    const rdr = &file_rdr.interface;

    const bytes = try rdr.allocRemainingAlignedSentinel(allocator, .unlimited, .@"1", 0);
    defer allocator.free(bytes);

    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSlice(Config, allocator, bytes, &diag, .{}) catch |err| {
        switch (err) {
            error.ParseZon => {
                var allocating = std.Io.Writer.Allocating.init(allocator);

                const writer = &allocating.writer;
                try diag.format(writer);

                const why = try allocating.toOwnedSlice();
                defer allocator.free(why);

                log.err("Could not parse config file. Why: {s}", .{why});
            },
            else => {},
        }

        return err;
    };
}

/// TODO: Use a Well known location e.g. $XDG_CONFIG_DIR/zclip/zclip.zon.
pub fn fromWellKnown(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map) !Config {
    const config_dir_path = known.getPath(io, allocator, environ, .local_configuration) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                log.err("Failed to allocate memory for configuration dir path.", .{});
            },
            // For now we just call this synchronously.
            error.Canceled => unreachable,
        }

        return err;
    } orelse {
        log.err("Could not find the configuration directory for your machine. Consider passing an explicit path to your config!", .{});
        return error.DirectoryNotFound;
    };

    const config_path = try std.fmt.allocPrint(allocator, "{s}/zclip/zclip.zon", .{config_dir_path});
    allocator.free(config_dir_path);
    defer allocator.free(config_path);

    return try fromPath(io, allocator, config_path);
}
