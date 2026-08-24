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

const std = @import("std");
const Io = std.Io;

const argv = @import("argv");

const Network = @import("Network.zig");

const IS_DEBUG = @import("builtin").mode == .debug;

pub const DaemonOpts = struct {
    /// The path to the data directory to use.
    data_dir: ?[]const u8 = null,

    pub const help = .{
        .data_dir = .{
            .desc = "Set a path to the data directory",
        },
    };
};

pub const PeerOpts = struct {
    action: ?union(enum) {
        add: PeerAdd,
        list: void,
        rm: PeerRm,
        edit: PeerEdit,

        pub const help = .{
            .add = .{ .desc = "Add a peer by name and public key" },
            .list = .{ .desc = "List known peers" },
            .rm = .{ .desc = "Remove a peer by ID" },
            .edit = .{ .desc = "Edit a peers information by ID" },
        };

        pub const PeerEdit = struct {
            /// The local ID of the peer to edit.
            id: u64,
            clear_degraded: bool = false,
            pubkey: ?[]const u8 = null,
            nick: ?[]const u8 = null,
            host: ?[]const u8 = null,
            clear_host: bool = false,

            pub const help = .{
                .id = .{ .desc = "The local ID of the peer to edit." },
                .clear_degraded = .{ .desc = "Unsets degraded status for the peer if set." },
                .pubkey = .{ .desc = "The new public key for the peer." },
                .nick = .{ .desc = "The new nickname for the peer." },
                .host = .{ .desc = "The new hostname for the peer." },
                .clear_host = .{ .desc = "Clears the set hostname for the peer." },
            };

            pub const flags = .{
                .nick = .{ .short = 'n' },
                .pubkey = .{ .short = 'k' },
                .host = .{ .short = 'i' },
            };
        };

        pub const PeerAdd = struct {
            name: []const u8,
            pubkey: []const u8,
            host: ?[]const u8,

            force: bool = false,

            pub const positionals = .{
                .name,
                .pubkey,
                .host,
            };

            pub const help = .{
                .usage = "peer add nickname publickey (optional hostname)",
            };
        };

        pub const PeerRm = struct {
            id: u64,

            pub const positionals = .{
                .id,
            };

            pub const help = .{
                .usage = "peer rm id",
            };
        };
    },
};

const Subcommand = union(enum) {
    daemon: DaemonOpts,
    peer: PeerOpts,
    ident: void,
    // TODO: Not implemented yet.
    status: void,

    pub const help = .{
        .daemon = .{ .desc = "Run the zclip daemon" },
        .peer = .{ .desc = "Manage trusted peers" },
        .ident = .{ .desc = "Gets public key to share with peers" },
        .status = .{ .desc = "Show information about the running daemon" },
    };
};

pub const Opts = struct {
    /// Enables debug logging. Off by default in Release builds.
    /// This is false by default on other optimise modes.
    verbose: bool = IS_DEBUG,
    /// The path to the UNIX socket. Should override any config set if passed.
    socket_path: ?[]const u8 = null,
    /// The bind address to bind the Daemon to.
    bind_addr: ?IpAddress = null,
    /// The config file path to use.
    config_path: ?[]const u8 = null,

    command: ?Subcommand = null,

    pub const flags = .{
        .verbose = .{ .short = 'v' },
        .config_path = .{ .short = 'c' },
        .bind_addr = .{ .short = 'a' },
        .socket_path = .{ .short = 'p' },
    };

    pub const help = .{
        .usage = "usage: zclip [options] <command> [command options]",
        .verbose = .{
            .desc = "Set the default log level to debug",
            .default = IS_DEBUG,
        },
        .socket_path = .{
            .desc = "The path to use for the UNIX socket, overriding any configured value",
        },
        .bind_addr = .{
            .desc = "The address:port to bind the daemon to. If the port is empty, 48500 is used",
        },
        .config_path = .{
            .desc = "Set a path to the configuration file",
        },
        .command = .{
            .desc = "The command to use",
        },
    };
};

pub const IpAddress = struct {
    addr: Io.net.IpAddress,

    pub fn parse(ctx: *argv.Parse.ValueCtx) !IpAddress {
        const arg = ctx.takeArg() orelse return error.MissingValue;

        return .{ .addr = try Network.parseIp(arg) };
    }
};
