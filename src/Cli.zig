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
const clap = @import("clap");
const zclip = @import("zclip");

pub const Parse = @import("cli/parse.zig");
pub const parse = Parse.parse;

pub const Validate = @import("cli/Validate.zig");
const Network = @import("Network.zig");

const SubCommands = enum {
    /// Client is default for ergonomics, since the daemon can be started as a service.
    client,
    daemon,
};

const main_parsers = .{
    .str = clap.parsers.string,
    .command = clap.parsers.enumeration(SubCommands),
};

// To pass around arguments returned by clap, `clap.Result` and `clap.ResultEx` can be used to
// get the return type of `clap.parse` and `clap.parseEx`.
const MainArgs = clap.ResultEx(clap.Help, &params, main_parsers);

// pub fn setupAndParseArgs(io: Io, arena: *ArenaAllocator, args: std.process.Args, opts: *CliOpts) !void {
//     Validate.validate(CliOpts);

//     const alloc = arena.allocator();
//     var iter = try args.iterateAllocator(alloc);
//     defer iter.deinit();

//     _ = iter.next();

//     var stderr_buf: [1024]u8 = undefined;
//     var stderr_file = Io.File.stderr();

//     var file_writer = stderr_file.writer(io, &stderr_buf);
//     var writer = &file_writer.interface;

//     var diag: clap.Diagnostic = .{};
//     var res = clap.parseEx(
//         clap.Help,
//         &params,
//         main_parsers,
//         &iter,
//         .{
//             .diagnostic = &diag,
//             .allocator = alloc,
//             // We want to stop at the first positional since it is a subcommand.
//             .terminating_positional = 0,
//         },
//     ) catch |err| {
//         try diag.reportToFile(io, .stderr(), err);
//         return err;
//     };
//     defer res.deinit();

//     if (res.args.help != 0) {
//         try printHelp(writer, params[0..], .{});

//         opts.should_exit = true;
//         return;
//     }

//     if (res.args.version != 0) {
//         if (build_options.git_rev) |rev| {
//             try writer.print(
//                 "zclip {s} ({s})\n",
//                 .{ build_options.version, rev },
//             );
//         } else {
//             try writer.print(
//                 "zclip {s}\n",
//                 .{build_options.version},
//             );
//         }

//         try writer.flush();

//         opts.should_exit = true;
//         return;
//     }

//     if (res.args.verbose != 0) {
//         opts.verbose = true;
//     }

//     if (res.args.config) |cfg| {
//         opts.config_path = cfg;
//     }

//     if (res.args.data) |data| {
//         opts.command.?.daemon. = data;
//     }

//     const mode = res.positionals[0];
//     if (mode == null) {
//         try printHelp(writer, params[0..], .{});
//         opts.should_exit = true;

//         return;
//     }

//     switch (mode.?) {
//         .client => {
//             opts.mode = .Client;

//             if (try parseClientArgs(io, alloc, &iter, res, opts, writer)) {
//                 opts.should_exit = true;
//                 return;
//             }
//         },
//         .daemon => {
//             opts.mode = .Daemon;

//             if (try parseDaemonArgs(io, alloc, &iter, res, opts, writer)) {
//                 opts.should_exit = true;
//                 return;
//             }
//         },
//     }
// }

/// TODO: Extend the client to take a variety of subcommands. Returns true if we should exit.
fn parseClientArgs(io: Io, alloc: Allocator, iter: *std.process.Args.Iterator, _: MainArgs, opts: *CliOpts, writer: *Io.Writer) !bool {
    const client_params = comptime clap.parseParamsComptime(
        \\ -h, --help               Display this help menu.
        \\ --socket-addr <str>      Use a different socket address for the daemon.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &client_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };

    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp(writer, client_params[0..], .{ .subcommand = "client" });

        return true;
    }

    if (res.args.@"socket-addr") |addr| {
        opts.socket_path = try alloc.dupe(u8, addr);
    }

    return false;
}

fn parseAddr() fn ([]const u8) Io.net.IpAddress.ParseLiteralError!Io.net.IpAddress {
    return struct {
        pub fn parse(addr: []const u8) !Io.net.IpAddress {
            var ip_addr = try Io.net.IpAddress.parseLiteral(addr);
            if (ip_addr.getPort() == 0) {
                ip_addr.setPort(Network.DEFAULT_NET_PORT);
            }

            return ip_addr;
        }
    }.parse;
}

/// Returns true if should quit.
fn parseDaemonArgs(io: Io, alloc: Allocator, iter: *std.process.Args.Iterator, _: MainArgs, opts: *CliOpts, writer: *Io.Writer) !bool {
    const parsers = .{
        .string = clap.parsers.string,
        .str = clap.parsers.string,
        .u8 = clap.parsers.int(u8, 0),
        .u16 = clap.parsers.int(u16, 0),
        .u32 = clap.parsers.int(u32, 0),
        .u64 = clap.parsers.int(u64, 0),
        .usize = clap.parsers.int(usize, 0),
        .i8 = clap.parsers.int(i8, 0),
        .i16 = clap.parsers.int(i16, 0),
        .i32 = clap.parsers.int(i32, 0),
        .i64 = clap.parsers.int(i64, 0),
        .isize = clap.parsers.int(isize, 0),
        .f32 = clap.parsers.float(f32),
        .f64 = clap.parsers.float(f64),
        .addr = parseAddr(),
    };

    const daemon_params = comptime clap.parseParamsComptime(
        \\ -h, --help               Display this help menu.
        \\ --socket-addr <str>      Use a different socket address for the daemon.
        \\ -b,--bind-addr <addr>    The address:port to bind the daemon to. Defaults to 0.0.0.0:48500.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &daemon_params, &parsers, iter, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };

    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp(writer, daemon_params[0..], .{ .subcommand = "daemon" });

        return true;
    }

    if (res.args.@"socket-addr") |addr| {
        opts.socket_path = try alloc.dupe(u8, addr);
    }

    if (res.args.@"bind-addr") |addr| {
        opts.bind_addr = .{ .addr = addr };
    }

    return false;
}

fn printPreamble(subcommand: []const u8, writer: *Io.Writer) !void {
    const fmt =
        \\ zclip {s}
        \\
        \\ A program to manage your clipboard, including over a network.
        \\
        \\
    ;

    try writer.print(fmt, .{subcommand});
    try writer.flush();
}

fn printPostscript(writer: *Io.Writer) !void {
    try writer.print(postscript, .{});
    try writer.flush();
}

const HelpOpts = struct {
    subcommand: []const u8 = "",
    passthrough: clap.HelpOptions = .{},
};

fn printHelp(writer: *Io.Writer, help_params: []const clap.Param(clap.Help), help_opts: HelpOpts) !void {
    try printPreamble(help_opts.subcommand, writer);

    try clap.help(writer, clap.Help, help_params, help_opts.passthrough);

    try printPostscript(writer);
}

const postscript =
    \\
    \\ This program is distributed in the hope that it will be useful,
    \\ but WITHOUT ANY WARRANTY; without even the implied warranty of
    \\ MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    \\ GNU General Public License for more details.
    \\
;

const params = clap.parseParamsComptime(
    \\ -h, --help           Display this help and exit
    \\ --version            Show the version of the software
    \\ -v, --verbose        Set the default log level to debug
    \\ -c, --config  <str>  Set a path to the configuration file
    \\ -d, --data    <str>  Set a path to the data directory
    \\ <command>            Subcommands: peer, daemon
);

pub const Mode = enum {
    /// Connects to the UNIX socket. Could be used for a GUI.
    Client,
    /// Manages the clipboard and makes a UNIX socket. TODO: Check this works on Windows.
    Daemon,
};

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

const CliSubcommand = union(enum) {
    daemon: DaemonOpts,
    peer: PeerOpts,
};

pub const CliOpts = struct {
    /// Enables debug logging. Off by default in Release builds.
    /// This is false by default on other optimise modes.
    verbose: bool = IS_DEBUG,
    mode: Mode = .Client,
    /// The path to the UNIX socket. Should override any config set if passed.
    socket_path: ?[]const u8 = null,
    /// True when help or usage was printed etc. TODO: Move to parser.
    should_exit: bool = false,
    /// The bind address to bind the Daemon to.
    bind_addr: ?IpAddress = null,
    /// The config file path to use.
    config_path: ?[]const u8 = null,

    command: ?CliSubcommand = null,

    pub const flags = .{
        .mode = .{ .short = 'm' },
        .verbose = .{ .short = 'v' },
    };

    pub const help = .{
        .usage = "usage: zclip [options] <command> [command options]",
        .verbose = .{
            .desc = "Set the default log level to debug",
            .default = IS_DEBUG,
        },
        .mode = .{
            .desc = "The selected subcommand",
            .default = .Client,
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

const IpAddress = struct {
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

// fn parseArgs(io: Io, arena: *ArenaAllocator, args: std.process.Args, opts: *CliOpts) !void {
//     _ = io; // autofix
//     _ = arena; // autofix
//     _ = args; // autofix
//     _ = opts; // autofix

//     // Short, long, description. A struct is used to get the types of arguments.
//     const root_flags = [_][3][]const u8{
//         &.{ "", "version", "Show the version of the software" },
//         &.{ "h", "help", "Show this help menu and exit" },
//         &.{ "c", "config-path", "A path to the config file" },
//         &.{ "d", "data-dir", "A path to the data directory" },
//         &.{ "v", "verbose", "Log harder" },
//         &.{ "s", "socket-path", "The path to use for the UNIX socket" },
//         &.{ "b", "bind-address", "IP:PORT to bind the daemon to.\nIf port empty, 48500 is used." },
//     };
//     _ = root_flags; // autofix
// }

// const Diagnostics = struct {
//     /// What went wrong.
//     message: []const u8,
//     /// The offending field.
//     field: []const u8,

//     should_free: bool = false,

//     /// For allocation of the strings.
//     alloc: Allocator,

//     pub fn init(alloc: Allocator) Diagnostics {
//         return .{
//             .message = &.{},
//             .field = &.{},
//             .alloc = alloc,
//         };
//     }

//     pub fn deinit(self: *Diagnostics) void {
//         if (!self.should_free) return;

//         self.alloc.free(self.message);
//         self.alloc.free(self.field);
//     }
// };
