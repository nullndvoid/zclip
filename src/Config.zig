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
const Base64 = std.base64.standard;

const known = @import("known-folders");
const toml = @import("toml");

const BACKEND_ALLOC_LIMIT_DEFAULT = 1024 * 1024 * 512;
const IS_DEBUG = @import("builtin").mode == .Debug;

const log = std.log.scoped(.config);

const Config = @This();

parsed: toml.Parsed(InnerConfig),
data: InnerConfig,

pub fn deinit(self: *Config) void {
    self.parsed.deinit();
}

/// Wrapped in Config because we want to manage the lifetimes of data allocated but
/// automatically parse into a struct.
pub const InnerConfig = struct {
    debugging: Debugging = .{},
    net: Network = .{},

    /// Optional memory limit for the process excluding I/O (futures). More useful for Debugging.
    const Debugging = struct {
        memory_limit: ?usize = if (IS_DEBUG) BACKEND_ALLOC_LIMIT_DEFAULT else null,
    };

    const Network = struct {
        pub const Peer = struct {
            /// NaCl Box public key. Should be 32 bytes in length once base 64 decoded.
            pubkey: []const u8,
            /// A nickname for the remote peer.
            nickname: []const u8,

            const Box = std.crypto.nacl.Box;

            /// Caller should free allocated slice.
            pub fn pubKey(self: *const Peer, alloc: Allocator) ![]u8 {
                const len = try Base64.Decoder.calcSizeForSlice(self.pubkey);
                if (len != Box.public_length) return error.InvalidInputLen;

                var buf = try alloc.alloc(u8, len);
                errdefer alloc.free(buf);

                try Base64.Decoder.decode(&buf, self.pubkey);

                return buf;
            }

            /// Caller should free allocated slice.
            pub fn encodePubKey(pubkey: [Box.public_length]u8, alloc: Allocator) ![]u8 {
                const len = Base64.Encoder.calcSize(pubkey.len);
                var buf = try alloc.alloc(u8, len);

                return Base64.Encoder.encode(&buf, pubkey);
            }
        };

        pub fn parseIp(self: Network) !?Io.net.IpAddress {
            if (self.daemon_bind_address == null) return null;

            var ip_addr = try Io.net.IpAddress.parseLiteral(self.daemon_bind_address.?);
            if (ip_addr.getPort() == 0) {
                ip_addr.setPort(@import("Network.zig").DEFAULT_NET_PORT);
            }

            return ip_addr;
        }

        /// A list of peers pubkeys, and their nicknames.
        peers: ?[]Peer = null,
        /// The address to bind the daemon to.
        daemon_bind_address: ?[]const u8 = null,
    };
};

fn parseSlice(allocator: Allocator, data: []const u8, filename: []const u8) !Config {
    var parser = toml.Parser(InnerConfig).init(allocator);
    defer parser.deinit();

    const parsed = parser.parseString(data) catch |err| {
        const info = parser.error_info orelse return err;

        switch (info) {
            .parse => |pos| {
                log.err("TOML parse error in {s} ({d}:{d})", .{ filename, pos.line, pos.pos });
            },
            .struct_mapping => |mapping| {
                log.err("TOML error mapping input to config struct. More info below:", .{});
                for (mapping) |map| {
                    log.err("Missing field/table: {s}. See README for information on configuring zclip.", .{map});
                }
            },
        }

        return err;
    };

    return .{
        .data = parsed.value,
        .parsed = parsed,
    };
}

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

    const bytes = try rdr.allocRemaining(allocator, .unlimited);
    defer allocator.free(bytes);

    return try parseSlice(allocator, bytes, std.fs.path.basename(absolute_path));
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
