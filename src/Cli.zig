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
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const build_options = @import("options");
const clap = @import("clap");
const zclip = @import("zclip");

const SubCommands = enum {
    /// Client is default for ergonomics, since the daemon can be started as a service.
    client,
    daemon,
};

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};

// To pass around arguments returned by clap, `clap.Result` and `clap.ResultEx` can be used to
// get the return type of `clap.parse` and `clap.parseEx`.
const MainArgs = clap.ResultEx(clap.Help, &params, main_parsers);

pub fn setupAndParseArgs(io: Io, arena: *ArenaAllocator, args: std.process.Args, opts: *CliOpts) !void {
    const alloc = arena.allocator();
    var iter = try args.iterateAllocator(alloc);
    defer iter.deinit();

    _ = iter.next();

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file = Io.File.stderr();

    var file_writer = stderr_file.writer(io, &stderr_buf);
    var writer = &file_writer.interface;

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(
        clap.Help,
        &params,
        main_parsers,
        &iter,
        .{
            .diagnostic = &diag,
            .allocator = alloc,
            // We want to stop at the first positional since it is a subcommand.
            .terminating_positional = 0,
        },
    ) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp(writer, params[0..], .{});

        opts.should_exit = true;
        return;
    }

    if (res.args.version != 0) {
        if (build_options.git_rev) |rev| {
            try writer.print(
                "zclip {s} ({s})\n",
                .{ build_options.version, rev },
            );
        } else {
            try writer.print(
                "zclip {s}\n",
                .{build_options.version},
            );
        }

        try writer.flush();

        opts.should_exit = true;
        return;
    } else if (res.args.verbose != 0) {
        opts.verbose = true;
    }

    const mode = res.positionals[0];
    if (mode == null) {
        try printHelp(writer, params[0..], .{});
        opts.should_exit = true;

        return;
    }

    switch (mode.?) {
        .client => {
            opts.mode = .Client;

            if (try parseClientArgs(io, alloc, &iter, res, opts, writer)) {
                opts.should_exit = true;
                return;
            }
        },
        .daemon => {
            opts.mode = .Daemon;

            if (try parseDaemonArgs(io, alloc, &iter, res, opts, writer)) {
                opts.should_exit = true;
                return;
            }
        },
    }
}

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

/// Returns true if should quit.
fn parseDaemonArgs(io: Io, alloc: Allocator, iter: *std.process.Args.Iterator, _: MainArgs, opts: *CliOpts, writer: *Io.Writer) !bool {
    const daemon_params = comptime clap.parseParamsComptime(
        \\ -h, --help               Display this help menu.
        \\ --socket-addr <str>      Use a different socket address for the daemon.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &daemon_params, clap.parsers.default, iter, .{
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
    \\ -h, --help            Display this help and exit
    \\ --version             Show the version of the software
    \\ -v, --verbose         Set the default log level to debug
    \\ <command>             This should be client or daemon (default is client)
);

pub const Mode = enum {
    /// Connects to the UNIX socket. Could be used for a GUI.
    Client,
    /// Manages the clipboard and makes a UNIX socket. TODO: Check this works on Windows.
    Daemon,
};

const IS_DEBUG = @import("builtin").mode == .Debug;

pub const CliOpts = struct {
    /// Enables debug logging. Off by default in Release builds.
    /// This is false by default on other optimise modes.
    verbose: bool = IS_DEBUG,
    mode: Mode = .Client,
    /// The path to the UNIX socket. Should override any config set if passed.
    socket_path: ?[]const u8 = null,
    /// True when help or usage was printed etc.
    should_exit: bool = false,
};
