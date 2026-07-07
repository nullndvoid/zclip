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

//! Configuration for zclip. Pass an arena allocator in to manage lifetimes for you.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Base64 = std.base64.standard;

const known = @import("known-folders");
const Serde = @import("serde");

const Network = @import("Network.zig");

const BACKEND_ALLOC_LIMIT_DEFAULT = 1024 * 1024 * 512;
const IS_DEBUG = @import("builtin").mode == .Debug;

const log = std.log.scoped(.config);

const Config = @This();

data: InnerConfig,

pub fn deinit(self: *Config) void {
    _ = self; // autofix
}

/// Wrapped in Config because we want to manage the lifetimes of data allocated but
/// automatically parse into a struct.
pub const InnerConfig = struct {
    debugging: DebuggingSection = .{},
    daemon: DaemonSection = .{},
    client: ClientSection = .{},

    /// Optional memory limit for the process excluding I/O (futures). More useful for Debugging.
    const DebuggingSection = struct {
        memory_limit: ?usize = if (IS_DEBUG) BACKEND_ALLOC_LIMIT_DEFAULT else null,
    };

    const DaemonSection = struct {
        /// The address to bind the daemon to.
        bind_address: ?[]const u8 = null,

        /// The address to bind the UNIX socket to (or connect to).
        unix_socket_address: ?[]const u8 = null,

        /// The directory storing data such as keyfiles.
        data_dir: ?[]const u8 = null,

        /// A list of peers pubkeys, and their nicknames.
        peers: ?[]Network.Peer = null,
    };

    const ClientSection = struct {
        /// The address to bind the UNIX socket to (or connect to).
        unix_socket_address: ?[]const u8 = null,
    };
};

fn parseSlice(allocator: Allocator, data: []const u8, filename: []const u8) !Config {
    const cfg = Serde.toml.fromSlice(InnerConfig, allocator, data) catch |err| {
        log.err("Error parsing config at {s}: {t}", .{ filename, err });
        return err;
    };

    return .{ .data = cfg };
}

pub fn fromPath(io: Io, allocator: Allocator, path: []const u8) !Config {
    var config = Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.err("Config file not found at {s}.", .{path});
            },
            else => {
                log.err("Could not open config file at {s}. Reason: {t}", .{ path, err });
            },
        }
        return err;
    };

    defer config.close(io);

    var read_buf: [1024]u8 = undefined;
    var file_rdr = config.reader(io, &read_buf);
    const rdr = &file_rdr.interface;

    const bytes = try rdr.allocRemaining(allocator, .unlimited);
    defer allocator.free(bytes);

    return try parseSlice(allocator, bytes, std.fs.path.basename(path));
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

    const config_path = try std.fmt.allocPrint(allocator, "{s}/zclip/zclip.toml", .{config_dir_path});
    allocator.free(config_dir_path);
    defer allocator.free(config_path);

    return try fromPath(io, allocator, config_path);
}
