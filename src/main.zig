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
const Network = @import("Network.zig");

const log = std.log.scoped(.zclip);

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

    const cli_opts = try Cli.parseArgs(&arena, minimal.args);

    var envmap = try minimal.environ.createMap(gpa.allocator());
    defer envmap.deinit();

    var config: Config = undefined;
    defer config.deinit();

    if (cli_opts.config_path) |path| {
        config = try Config.fromPath(io, arena.allocator(), path);
    } else {
        config = try Config.fromWellKnown(io, arena.allocator(), &envmap);
    }

    const cfg = config.data;

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
        cfg.daemon.unix_socket_address orelse
        cfg.client.unix_socket_address orelse
        try getSocketPath(arena.allocator(), minimal.environ);

    // Get our own identity.
    if (cli_opts.command == null) {
        log.err("Please provide a command!", .{});
    }

    const command = cli_opts.command.?;

    var inet_cfg = Network.Config{};
    if (cfg.daemon.bind_address) |addr| {
        const ip = try Network.parseIp(addr);
        inet_cfg.bind_addr = ip;
    }

    if (cfg.daemon.peers) |peers| {
        for (peers) |*peer| {
            peer.fix(&arena) catch |err| {
                log.err("Could not use configured peer \"{s}\". Reason: {t}", .{ peer.nickname, err });
                // log.info("To add a peer, try `zclip peer add nickname public_key`", .{}); TODO: Add this for fun.
                // In all seriousness if I want the Daemon to run as a systemd service, then I will need an easy way
                // to talk to it.
            };
        }
        inet_cfg.peers = peers;
    }

    if (cli_opts.bind_addr) |addr| {
        inet_cfg.bind_addr = addr.addr;
    }

    switch (command) {
        .daemon => |daemon_opts| {
            const data_dir =
                daemon_opts.data_dir orelse
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
                },
            });
        },

        .peer => |peer| {
            _ = peer; // autofix
        },
    }

    // switch (command) {
    //     .Client => {
    //         var client_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    //         var client = try Client.init(io, &client_arena, .{
    //             .socket_path = socket_path,
    //         });
    //         defer client.deinit();

    //         try client.sendCommand(.GetPubkey);

    //         select.cancelDiscard();

    //         return;
    //     },
    // }

    const res = try select.await();
    switch (res) {
        .daemon => |result| result catch |err| {
            log.err("daemon exited with error: {t}", .{err});
        },
        else => {},
    }
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
