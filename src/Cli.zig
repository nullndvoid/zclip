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

const builtin = @import("std").builtin;
const Type = builtin.Type;
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const build_options = @import("options");
const zclip = @import("zclip");

pub const Parse = @import("cli/parse.zig");
pub const parse = Parse.parse;
pub const ParseCtx = Parse.ParseCtx;
pub const Diagnostics = Parse.Diagnostics;
pub const ParseError = Parse.ParseError;
const Validate = @import("cli/Validate.zig");
const Network = @import("Network.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

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

        pub const PeerAdd = struct {
            name: []const u8,
            pubkey: []const u8,

            force: bool = false,

            pub const positionals = .{
                .name,
                .pubkey,
            };
        };
    },
};

const Subcommand = union(enum) {
    daemon: DaemonOpts,
    peer: PeerOpts,
};

pub const Opts = struct {
    /// Enables debug logging. Off by default in Release builds.
    /// This is false by default on other optimise modes.
    verbose: bool = IS_DEBUG,
    /// The path to the UNIX socket. Should override any config set if passed.
    socket_path: ?[]const u8 = null,
    /// True when help or usage was printed etc. TODO: Move to parser.
    should_exit: bool = false,
    /// The bind address to bind the Daemon to.
    bind_addr: ?IpAddress = null,
    /// The config file path to use.
    config_path: ?[]const u8 = null,

    command: ?Subcommand = null,

    pub const flags = .{
        .verbose = .{ .short = 'v' },
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

    pub fn parse(ctx: *Parse.ParseCtx) !IpAddress {
        const arg = ctx.takeArg() orelse return error.MissingValue;

        var addr = try Io.net.IpAddress.parseLiteral(arg);
        if (addr.getPort() == 0) {
            addr.setPort(Network.DEFAULT_NET_PORT);
        }

        return .{ .addr = addr };
    }
};
