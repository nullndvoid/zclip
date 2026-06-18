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

//! Higher level clipboard management.

const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const zclip = @import("root.zig");
const Backend = zclip.Backend;
const Clip = zclip.Clip;
const ClipQueue = zclip.ClipQueue;

const log = std.log.scoped(.Clipboard);

backend: *Backend,
clips: ?Clip = null,
/// Used to send commands to the worker task.
commands_in: *CommandQueue,

/// The worker thread.
worker: Io.Future(anyerror!void),

io: Io,

pub const Command = union(enum) {
    /// Client requests the thread to stop.
    ///
    /// We are not likely to need a large buffer for `commands_in`.
    Stop,
    /// Client writes to the clipboard (manually). Not used for inbound network
    /// clips, as these can be written from the worker thread.
    ///
    ///
    /// We are not likely to need a large buffer for `commands_in`.
    WriteClipboard: Clip,
    /// Worker thread sends new clips from system and network to the client.
    ///
    /// TODO: Maybe we should make a separate command for network reads? like: (Network: Packet)
    Clip: Clip,
};

const CommandQueue = Io.Queue(Command);

const Clipboard = @This();

const WorkerContext = struct {
    io: Io,
    alloc: Allocator,
    in: *CommandQueue,
    out: *CommandQueue,
    clip_queue: *ClipQueue,
    backend: *Backend,
};

/// Returns error.Stop if we should stop the worker without error.
fn pollInCommands(ctx: *WorkerContext, buf: []Command) anyerror!void {
    const in_commands_read = ctx.in.get(ctx.io, buf, 0) catch |err| switch (err) {
        error.Canceled => {
            log.err("Async task cancelled, must be shutting down. Some data may be lost.", .{});
            return;
        },
        error.Closed => {
            log.err("Commands in channel closed, must be shutting down. Some data may be lost.", .{});
            return;
        },
    };
    const commands = buf[0..in_commands_read];

    for (commands) |cmd| {
        switch (cmd) {
            .Stop => return error.Stop,
            .WriteClipboard => |clip| {
                try ctx.backend.setClipboard(clip);
            },
            else => return error.InvalidCommand,
        }
    }
}

/// # Errors
///
/// Returns `InvalidCommand` on reciept of invalid commands.
///
/// Checks in commands, reads system clipboard, then writes those `Clip`s as commands for the frontend.
///
/// # TODO:
///
/// Poll the network.
fn workerFn(ctx: *WorkerContext) anyerror!void {
    // Prealloc some buffers for the queue reads.
    const clip_queue_buf = try ctx.alloc.alloc(Clip, ctx.clip_queue.queue.capacity());
    defer ctx.alloc.free(clip_queue_buf);

    const commands_in_buf = try ctx.alloc.alloc(Command, ctx.in.capacity());
    defer ctx.alloc.free(commands_in_buf);

    const commands_out_buf = try ctx.alloc.alloc(Command, ctx.out.capacity());
    defer ctx.alloc.free(commands_out_buf);

    var out_commands = commands_out_buf;

    while (true) {
        pollInCommands(ctx, commands_in_buf) catch |err| switch (err) {
            error.Stop => break,
            else => return err,
        };

        const clips_read = ctx.clip_queue.queue.get(ctx.io, clip_queue_buf, 0) catch |err| switch (err) {
            // TODO: These might be handled already on deinit since we will check incoming commands first to cancel everything below.
            error.Canceled => {
                log.err("Async task cancelled, must be shutting down. Some data may be lost.", .{});
                return;
            },
            error.Closed => {
                log.err("Clip read channel closed, must be shutting down. Some data may be lost.", .{});
                return;
            },
        };

        const clips = clip_queue_buf[0..clips_read];

        for (clips, 0..) |clip, idx| {
            out_commands[idx] = .{ .Clip = clip };
        }

        // Now write the read clips. We can poll in commands whilst waiting instead of blocking with putAll.
        var written: usize = 0;
        while (written < clips_read) {
            out_commands = out_commands[written..clips_read];
            written += try ctx.out.put(ctx.io, out_commands, 0);

            pollInCommands(ctx, commands_in_buf) catch |err| switch (err) {
                error.Stop => return,
                else => return err,
            };
        }
    }
}

/// Need to make a worker thread that takes commands over a channel, reads from network* and clipboard, and displays them.
///
/// # Notes
///
/// Networking not implemented yet.
///
/// For now we can just have a list of clippings rendered and a simple TUI? Or start writing a GUI but I would like this
/// to be able to run in the CLI as well, or some sort of daemon.
pub fn init(io: Io, arena: *ArenaAllocator, config: Config) !Clipboard {
    const read_clip_queue = try arena.allocator().create(ClipQueue);
    read_clip_queue.* = try zclip.ClipQueue.init(
        io,
        arena.allocator(),
        .{ .buffer_size = 5 },
    );

    const backend = try Backend.init(io, arena, read_clip_queue);

    const commands_in_buf = try arena.allocator().alloc(
        Command,
        config.commands_in_buf_size,
    );

    const commands_out_buf = try arena.allocator().alloc(
        Command,
        config.commands_out_buf_size,
    );

    const commands_in = try arena.allocator().create(CommandQueue);
    const commands_out = try arena.allocator().create(CommandQueue);

    commands_in.* = CommandQueue.init(commands_in_buf);
    commands_out.* = CommandQueue.init(commands_out_buf);

    const worker_ctx = try arena.allocator().create(WorkerContext);
    worker_ctx.* = .{
        .in = commands_in,
        .out = commands_out,
        .clip_queue = read_clip_queue,
        .io = io,
        .alloc = arena.allocator(),
        .backend = backend,
    };

    return .{
        .io = io,
        .backend = backend,
        .commands_in = commands_in,
        .worker = try io.concurrent(workerFn, .{worker_ctx}),
    };
}

/// Stops the running backend and worker thread.
pub fn deinit(self: *Clipboard) void {
    self.commands_in.putOneUncancelable(self.io, .Stop) catch {
        log.err("Worker task commands in queue closed. Cancelling tasks.", .{});
        self.worker.cancel(self.io) catch |err| {
            log.err("Worker task died with error: {t}", .{err});
        };
    };

    self.worker.await(self.io) catch |err| {
        log.err("Worker task died with error: {t}", .{err});
    };

    self.backend.deinit();
}

/// Intended for use by unit tests etc. Blocking.
pub fn sendCommandRaw(self: *Clipboard, cmd: Command) !void {
    try self.commands_in.putOne(self.io, cmd);
}

pub const Config = struct {
    /// We are not likely to need a large buffer for `commands_in`.
    commands_in_buf_size: usize = 2,
    commands_out_buf_size: usize = 5,
    /// Writes should not take long but just as a guess I will say 5.
    /// Wants tuning later.
    pending_writes_buf_size: usize = 5,
};
