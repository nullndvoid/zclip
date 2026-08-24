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

const argv = @import("argv");
const opts = @import("options");

const Cli = @import("Cli.zig");
const Client = @import("Client.zig");
const Config = @import("Config.zig");
const Daemon = @import("Daemon.zig");
const Log = @import("log.zig");
const Network = @import("Network.zig");
const util = @import("util.zig");

const log = std.log.scoped(.zclip);

/// Magic number is the length of our public keys when base64 encoded.
///
/// Validated by client but just in case we had some malicious or broken
/// program, or regressions in the client, we should check this server side.
///
/// This reads like a clanker wrote it. It did not.
const PUBKEY_LEN_B64 = 44;

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
    var diag = argv.Diagnostics{};
    const help_cfg = argv.HelpOpts{
        .program_name = "zclip",
        .program_desc = "A tool to share your clipboard across systems.",
    };

    var ctx = argv.ParseCtx(Cli.Opts).init(
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
            error.MissingPositional => {
                log.err("{s}", .{diag.message});

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

    if (cli_opts.command == null) {
        try ctx.writeHelp(help_cfg, writer);
        return;
    }

    var envmap = try minimal.environ.createMap(gpa.allocator());
    defer envmap.deinit();

    var config: Config = .default;
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

    const command = cli_opts.command.?;

    var inet_cfg = Network.Config{};
    if (cfg.daemon.bind_address) |addr| {
        const ip = try Network.parseIp(addr);
        inet_cfg.bind_addr = ip;
    }

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

        var daemon = Daemon.init(io, gpa.allocator(), ident, .{
            .socket_path = socket_path,
            .inet = inet_cfg,
            .data_dir = data_dir,
        });
        defer daemon.deinit();

        try select.concurrent(.daemon, Daemon.start, .{&daemon});

        var res = try select.await();
        if (res == .signal) {
            daemon.stop();
            interrupt_event.reset();
            try select.concurrent(.signal, waitForInterrupt, .{});

            res = try select.await();
            if (res == .signal) {
                log.warn("Interrupted again. Forcing shutdown.", .{});
                select.cancelDiscard();
                return;
            }
        }

        switch (res) {
            .daemon => |result| result catch |err| {
                log.err("daemon exited with error: {t}", .{err});
            },
            .signal => {},
        }

        return;
    }

    switch (command) {
        .version => {
            const version = opts.version;

            try stdout_writer.print("{s}\n", .{version});
            try stdout_writer.flush();
        },
        .daemon => unreachable,
        .ident => {
            var client_arena = std.heap.ArenaAllocator.init(gpa.allocator());
            var client = try Client.init(io, &client_arena, .{
                .socket_path = socket_path,
            });
            defer client.deinit();

            const pubkey_bytes = try client.getPubkey();
            const pubkey = util.encodeKey(pubkey_bytes);

            try stdout_writer.writeAll(&pubkey);
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
                        if (add.pubkey.len != PUBKEY_LEN_B64) {
                            log.err("Public key base64 has invalid length!", .{});
                            std.process.exit(1);
                        }

                        const pubkey = util.decodeKey(add.pubkey[0..add.pubkey.len]) catch {
                            log.err("Public key should be base64 encoded!", .{});
                            std.process.exit(1);
                        };

                        const host: ?Network.Host = if (add.host) |host_str|
                            try Network.Host.parse(host_str)
                        else
                            null;

                        try client.addPeer(.{
                            .host = host,
                            .pubkey = pubkey,
                            .nickname = add.name,
                        }, add.force);
                    },
                    .list => {
                        const peers = try client.listPeers();

                        try printPeers(peers, stdout_writer);
                    },
                    .rm => |rm| {
                        client.removePeer(rm.id) catch |err| {
                            if (err == error.DaemonError) {
                                log.err("Could not remove peer #{d}. Does it exist?", .{rm.id});
                                std.process.exit(1);
                            }

                            return err;
                        };
                    },
                    .edit => |edit| {
                        if (edit.pubkey) |pk| if (pk.len != PUBKEY_LEN_B64) {
                            log.err("Public key base64 has invalid length!", .{});
                            std.process.exit(1);
                        };

                        client.editPeer(edit.id, .{
                            .clear_degraded = edit.clear_degraded,
                            .pubkey = edit.pubkey,
                            .nick = edit.nick,
                            .host = edit.host,
                            .clear_host = edit.clear_host,
                        }) catch |err| {
                            if (err == error.DaemonError) {
                                log.err("Could not edit peer #{d}. See logs for reason.", .{edit.id});
                                std.process.exit(1);
                            }

                            return err;
                        };
                    },
                }
            } else {
                try ctx.writeHelp(help_cfg, writer);
            }
        },
        // TODO: Not implemented yet.
        .status => {
            log.err("Not implemented yet!", .{});
            std.process.exit(1);
        },
    }
}

fn printPeers(peers: []const Network.Peer, writer: *Io.Writer) !void {
    if (peers.len == 0) {
        try writer.print("There are no peers added. Try adding one with `zclip peer add`", .{});
        try writer.flush();
    }

    for (peers) |p| {
        const pubkey = util.encodeKey(p.pubkey);

        if (p.host) |addr| {
            try writer.print("ID {d}: {s} ({s}) {f}\n", .{ p.id, p.nickname, &pubkey, addr });
        } else try writer.print("ID {d}: {s} ({s})\n", .{ p.id, p.nickname, &pubkey });
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
// SAFETY: This is initialised before signal handling is set up.
var io: Io = undefined;
/// Global for signal handler usage.
// SAFETY: This is initialised before signal handling is set up.
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

test {
    std.testing.refAllDecls(@This());
}
