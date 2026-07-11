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

const Cli = @import("Cli.zig");
const Client = @import("Client.zig");
const Config = @import("Config.zig");
const Daemon = @import("Daemon.zig");
const Log = @import("log.zig");
const Network = @import("Network.zig");
const Repo = @import("Repo.zig");
const util = @import("util.zig");

const log = std.log.scoped(.zclip);

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = Log.logFn,
};

pub fn main(minimal: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
    }).init;

    var io_gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = io_gpa.deinit();

    var io_impl = Io.Threaded.init(io_gpa.allocator(), .{});
    defer io_impl.deinit();

    io = io_impl.io();

    defer {
        const leaks = gpa.deinit();
        if (leaks == .leak) {
            log.warn("Memory leaked from allocator.", .{});
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const stdout = std.Io.File.stdout();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_fw = stdout.writer(io, &stdout_buf);
    const stdout_writer = &stdout_fw.interface;

    const stderr = std.Io.File.stderr();
    var stderr_buf: [1024]u8 = undefined;
    var stderr_fw = stderr.writer(io, &stderr_buf);
    const writer = &stderr_fw.interface;

    const args = try minimal.args.toSlice(arena.allocator());
    var diag = Cli.Diagnostics{};
    const help_cfg = Cli.HelpOpts{
        .program_name = "zclip",
        .program_desc = "A tool to share your clipboard across systems.",
    };

    var ctx = Cli.ParseCtx(Cli.Opts).init(
        arena.allocator(),
        args[1..],
        &diag,
    );

    const cli_opts = ctx.parse() catch |err| {
        switch (err) {
            error.HelpRequested => {
                try ctx.writeHelp(help_cfg, writer);

                return;
            },
            else => {},
        }

        log.err("Could not parse args. Reason: {t}", .{err});
        log.err("Message: {s}", .{diag.message});
        try writer.print("Use zclip --help for an overview of options.", .{});
        std.process.exit(1);
    };

    Log.level = if (cli_opts.verbose) .debug else .info;

    var envmap = try minimal.environ.createMap(gpa.allocator());
    defer envmap.deinit();

    var config: Config = undefined;
    defer config.deinit();

    if (cli_opts.config_path) |path| {
        config = try Config.fromPath(io, arena.allocator(), path);
    } else {
        config = try Config.fromWellKnown(io, arena.allocator(), &envmap);
    }

    const cfg = config.get();

    if (cfg.debugging.memory_limit) |limit| {
        gpa.requested_memory_limit = limit;
    }

    const TaskResult = union(enum) {
        daemon: (anyerror || std.Io.Cancelable)!void,
        signal: std.Io.Cancelable!void,
    };

    var buffer: [2]TaskResult = undefined;
    var select: std.Io.Select(TaskResult) = .init(io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.signal, waitForInterrupt, .{});

    const socket_path = cli_opts.socket_path orelse
        cfg.unix_socket_address orelse
        try getSocketPath(arena.allocator(), minimal.environ);

    if (cli_opts.command == null) {
        try ctx.writeHelp(help_cfg, writer);
        return;
    }

    const command = cli_opts.command.?;

    var inet_cfg = Network.Config{};
    if (cfg.daemon.bind_address) |addr| {
        const ip = try Network.parseIp(addr);
        inet_cfg.bind_addr = ip;
    }

    // TODO: Fetch peers from DB. Config should be static for the most part.
    // if (cfg.daemon.peers) |peers| {
    //     inet_cfg.peers = peers;
    // }

    if (cli_opts.bind_addr) |addr| {
        inet_cfg.bind_addr = addr.addr;
    }

    if (command == .daemon) {
        const daemon_cli_opts = command.daemon;

        const data_dir =
            daemon_cli_opts.data_dir orelse
            cfg.daemon.data_dir orelse
            try Network.Identity.getWellKnownDir(io, arena.allocator(), &envmap);

        const ident = try Network.Identity.getOrInit(
            io,
            arena.allocator(),
            data_dir,
        );

        try select.concurrent(.daemon, runDaemon, .{
            &arena,
            ident,
            Daemon.Opts{
                .socket_path = socket_path,
                .inet = inet_cfg,
                .data_dir = data_dir,
            },
        });

        const res = try select.await();
        switch (res) {
            .daemon => |result| result catch |err| {
                log.err("daemon exited with error: {t}", .{err});
            },
            else => {},
        }

        return;
    }

    switch (command) {
        .daemon => unreachable,
        .ident => {
            var client_arena = std.heap.ArenaAllocator.init(gpa.allocator());
            var client = try Client.init(io, &client_arena, .{
                .socket_path = socket_path,
            });
            defer client.deinit();

            const pubkey_bytes = try client.getPubkey();
            const pubkey = try util.base64encode(&pubkey_bytes, gpa.allocator());
            defer gpa.allocator().free(pubkey);

            try stdout_writer.writeAll(pubkey);
            try stdout_writer.flush();
        },
        .peer => |peer| {
            if (peer.action) |act| {
                var client_arena = std.heap.ArenaAllocator.init(gpa.allocator());
                var client = try Client.init(io, &client_arena, .{
                    .socket_path = socket_path,
                });
                defer client.deinit();

                switch (act) {
                    .add => |add| {
                        const pubkey = util.base64decode(add.pubkey, gpa.allocator()) catch {
                            log.err("Public key should be base64 encoded!", .{});
                            std.process.exit(1);
                        };

                        defer gpa.allocator().free(pubkey);
                        if (pubkey.len != 32) {
                            log.err("Public key should decode to 32 bytes! Got {d}", .{pubkey.len});
                            std.process.exit(1);
                        }

                        try client.addPeer(.{
                            .addr = add.addr,
                            .pubkey = pubkey[0..32].*,
                            .nickname = add.name,
                        }, add.force);
                    },
                    .list => {
                        const peers = try client.listPeers();

                        try printPeers(peers, gpa.allocator(), stdout_writer);
                    },
                }
            } else {
                try ctx.writeHelp(help_cfg, writer);
            }
        },
    }
}

fn printPeers(peers: []const Network.Peer, alloc: Allocator, writer: *Io.Writer) !void {
    for (peers) |p| {
        const pubkey = try util.base64encode(&p.pubkey, alloc);
        defer alloc.free(pubkey);
        if (p.addr) |addr| {
            try writer.print("ID {d}: {s} ({s}) {s}\n", .{ p.id, p.nickname, p.pubkey, addr });
        } else try writer.print("ID {d}: {s} ({s})\n", .{ p.id, p.nickname, pubkey });
    }

    try writer.writeAll("\n");
    try writer.flush();
}

/// TODO: Support Windows. Caller is responsible for freeing returned memory.
fn getSocketPath(alloc: Allocator, env: std.process.Environ) ![]const u8 {
    const runtime_dir = try env.getAlloc(alloc, "XDG_RUNTIME_DIR");
    defer alloc.free(runtime_dir);

    return try std.fmt.allocPrint(alloc, "{s}/zclip.sock", .{runtime_dir});
}

/// Global for signal handler usage.
var io: Io = undefined;
/// Global for signal handler usage.
var interrupt_event: std.Io.Event = .unset;

/// Sets up signal handling and waits until an interrupt is recieved.
const waitForInterrupt = switch (@import("builtin").os.tag) {
    .linux => waitForInterruptPosix,
    .windows => waitForInterruptWin32,
    else => @compileError("TODO"),
};

fn waitForInterruptWin32() std.Io.Cancelable!void {
    @panic("TODO");
}

fn waitForInterruptPosix() std.Io.Cancelable!void {
    const action: std.posix.Sigaction = .{
        .handler = .{
            .handler = struct {
                fn handler(_: std.posix.SIG) callconv(.c) void {
                    interrupt_event.set(io);
                }
            }.handler,
        },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);

    try interrupt_event.wait(io);
    log.info("Got a signal, stopping gracefully...", .{});
}

fn runDaemon(arena: *std.heap.ArenaAllocator, identity: Network.Identity, opts: Daemon.Opts) (std.Io.Cancelable || anyerror)!void {
    var daemon = Daemon.init(io, arena, identity, opts);
    defer daemon.deinit();

    try daemon.start();
}

test {
    std.testing.refAllDecls(@This());
}
