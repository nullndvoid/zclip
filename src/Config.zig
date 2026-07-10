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
//! You should call .deinit when done with this. Accepts absolute and relative paths.

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

/// This field should not be accessed directly. Instead call `Config.get` for a copy.
data: InnerConfig,
path: []const u8,
dir: Io.Dir,
io: Io,
alloc: Allocator,

pub fn deinit(self: *Config) void {
    self.dir.close(self.io);
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

fn toSlice(cfg: InnerConfig, allocator: Allocator) ![]const u8 {
    return try Serde.toml.toSlice(allocator, cfg);
}

fn parseSlice(io: Io, allocator: Allocator, data: []const u8, path: []const u8, dir: Io.Dir) !Config {
    const cfg = Serde.toml.fromSlice(InnerConfig, allocator, data) catch |err| {
        log.err("Error parsing config at {s}: {t}", .{ path, err });
        return err;
    };

    return .{
        .data = cfg,
        .path = path,
        .io = io,
        .alloc = allocator,
        .dir = dir,
    };
}

/// The opened dir must outlive Config. Just call deinit on this Config.
fn fromPathWithDir(io: Io, dir: Io.Dir, allocator: Allocator, path: []const u8) !Config {
    var config = dir.openFile(io, path, .{}) catch |err| {
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

    return try parseSlice(io, allocator, bytes, try allocator.dupe(u8, path), dir);
}

pub fn fromPath(io: Io, allocator: Allocator, path: []const u8) !Config {
    return try fromPathWithDir(io, Io.Dir.cwd(), allocator, path);
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

/// Gets a copy of the configuration data.
pub fn get(cfg: Config) InnerConfig {
    return cfg.data;
}

/// Updates the inner config. Call `Config.get` for a copy of the internal data.
/// Do not update `.data` directly, this is in case an update fails.
pub fn update(cfg: *Config, new_config: InnerConfig) !void {
    const bytes = try toSlice(new_config, cfg.alloc);

    var atomic_file = try cfg.dir.createFileAtomic(
        cfg.io,
        cfg.path,
        .{ .replace = true },
    );
    defer atomic_file.deinit(cfg.io);

    var writer_buf: [1024]u8 = undefined;

    var af_writer = atomic_file.file.writer(cfg.io, &writer_buf);
    const writer = &af_writer.interface;

    try writer.writeAll(bytes);
    try writer.flush();

    try atomic_file.replace(cfg.io);

    cfg.data = new_config;
}

test "read config" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const tmp_dir = std.testing.tmpDir(.{});

    // Write the config to test/config.toml.
    {
        const config =
            \\[daemon]
            \\bind_address = "127.0.0.1:48501"
            \\unix_socket_address = "./data/zclip_bob.sock"
            \\data_dir = "./data"
            \\
            \\[[daemon.peers]]
            \\nickname = "Alice"
            \\pubkey = "4EIP8HSpq2hx2jhqVOPWXf5Ri0JTdzTa5iP6091VTDc="
            \\addr = "127.0.0.1:48500"
        ;

        const file = try tmp_dir.dir.createFile(io, "config.toml", .{});
        defer file.close(io);

        var write_buf: [1024]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        const writer = &file_writer.interface;

        try writer.writeAll(config);
        try writer.flush();
    }

    const cfg = try Config.fromPathWithDir(io, tmp_dir.dir, arena.allocator(), "config.toml");

    const data = cfg.get();

    try std.testing.expectEqualStrings("./data", data.daemon.data_dir.?);
    try std.testing.expectEqualStrings("Alice", data.daemon.peers.?[0].nickname);
}

test Config {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // To avoid clobbering the example config on call to update.
    const f = try Io.Dir.createFileAbsolute(io, "/tmp/zclip.toml", .{});
    f.close(io);

    defer Io.Dir.deleteFileAbsolute(io, "/tmp/zclip.toml") catch {};

    {
        var cfg = try Config.fromPath(io, arena.allocator(), "/tmp/zclip.toml");
        var cfg_data = cfg.get();

        const peers = cfg_data.daemon.peers;

        _ = peers; // Do something with peers.

        cfg_data.client.unix_socket_address = "/tmp/zclip.sock";

        try cfg.update(cfg_data); // Updates the config with new data.

    }

    // Now we could re-open cfg and assert same.
    var tmp_dir = try Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp_dir.close(io);

    var cfg = try Config.fromPathWithDir(io, tmp_dir, arena.allocator(), "zclip.toml");

    const cfg_data = cfg.get();

    try std.testing.expectEqualStrings(
        "/tmp/zclip.sock",
        cfg_data.client.unix_socket_address.?,
    );
}
