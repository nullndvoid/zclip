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
clips: std.ArrayList(Clip),
/// Used to send commands to the worker task.
commands_in: *CommandQueue,
/// The worker thread.
worker: Io.Future(anyerror!void),
/// Used for initialisation of fields.
init_arena: ArenaAllocator,
/// Underlying allocator.
alloc: Allocator,
io: Io,
/// Clipboard callback. Users could also inspect the arraylist but this
/// provides a way to be notified immediately.
on_clipboard: ?*const fn (clip: *Clip, userdata: *anyopaque) anyerror!void,
/// Passed into on_clipboard.
userdata: ?*anyopaque,

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
};

const CommandQueue = Io.Queue(Command);

const Clipboard = @This();

const WorkerContext = struct {
    io: Io,
    alloc: Allocator,
    in: *CommandQueue,
    clip_queue: *ClipQueue,
    backend: *Backend,
};

pub fn setOnClip(self: *Clipboard, comptime T: type, comptime callback: fn (clip: *Clip, userdata: *T) anyerror!void, userdata: *T) void {
    self.on_clipboard = @ptrCast(@alignCast(&callback));
    self.userdata = @ptrCast(userdata);
}

/// Adds clips to the array list and calls the callback.
fn addClips(self: *Clipboard, clips: []Clip) void {
    for (clips) |clip| {
        if (self.clips.items.len == self.clips.capacity) {
            // TODO: Use a linked list perhaps?
            const removed = self.clips.orderedRemove(0);
            self.alloc.free(removed.data);
            self.alloc.free(removed.mime_type);
        }

        self.clips.appendAssumeCapacity(.{
            .data = clip.data,
            .mime_type = clip.mime_type,
            .is_text = clip.is_text,
        });

        if (self.on_clipboard) |cb| {
            cb(&self.clips.items[self.clips.items.len - 1], self.userdata.?) catch |err| {
                log.err("on_clip returned error: {t}", .{err});
            };
        }
    }
}

const WorkerEvent = union(enum) {
    commands: (Io.QueueClosedError || Io.Cancelable)!usize,
    clips: (Io.QueueClosedError || Io.Cancelable)!usize,
};

/// # Errors
///
/// Returns `InvalidCommand` on reciept of invalid commands.
///
/// Checks in commands, reads system clipboard, then writes those `Clip`s as commands for the frontend.
///
/// # TODO:
///
/// Poll the network.
fn workerFn(self: *Clipboard, ctx: *WorkerContext) anyerror!void {
    // Prealloc some buffers for the queue reads.
    const clip_queue_buf = try ctx.alloc.alloc(Clip, ctx.clip_queue.queue.capacity());
    defer ctx.alloc.free(clip_queue_buf);

    const commands_in_buf = try ctx.alloc.alloc(Command, ctx.in.capacity());
    defer ctx.alloc.free(commands_in_buf);

    var select_buf: [2]WorkerEvent = undefined;
    var select = Io.Select(WorkerEvent).init(ctx.io, &select_buf);
    defer select.cancelDiscard();

    try select.concurrent(.commands, Io.Queue(Command).get, .{ ctx.in, ctx.io, commands_in_buf, 1 });
    try select.concurrent(.clips, Io.Queue(Clip).get, .{ &ctx.clip_queue.queue, ctx.io, clip_queue_buf, 1 });

    while (true) {
        switch (try select.await()) {
            .commands => |result| {
                const commands_read = result catch |err| switch (err) {
                    error.Canceled => {
                        log.err("Async task cancelled, must be shutting down. Some data may be lost.", .{});
                        return;
                    },
                    error.Closed => {
                        log.err("Commands in channel closed, must be shutting down. Some data may be lost.", .{});
                        return;
                    },
                };

                for (commands_in_buf[0..commands_read]) |cmd| {
                    switch (cmd) {
                        .Stop => return,
                        .WriteClipboard => |clip| {
                            try ctx.backend.setClipboard(clip);
                        },
                    }
                }

                try select.concurrent(.commands, Io.Queue(Command).get, .{ ctx.in, ctx.io, commands_in_buf, 1 });
            },
            .clips => |result| {
                const clips_read = result catch |err| switch (err) {
                    error.Canceled => {
                        log.err("Async task cancelled, must be shutting down. Some data may be lost.", .{});
                        return;
                    },
                    error.Closed => {
                        log.err("Clip read channel closed, must be shutting down. Some data may be lost.", .{});
                        return;
                    },
                };

                addClips(self, clip_queue_buf[0..clips_read]);

                try select.concurrent(.clips, Io.Queue(Clip).get, .{ &ctx.clip_queue.queue, ctx.io, clip_queue_buf, 1 });
            },
        }
    }
}

pub fn init(io: Io, alloc: Allocator, config: Config) !*Clipboard {
    const self = try alloc.create(Clipboard);
    errdefer alloc.destroy(self);

    self.init_arena = ArenaAllocator.init(alloc);
    errdefer self.init_arena.deinit();

    const read_clip_queue = try self.init_arena.allocator().create(ClipQueue);
    read_clip_queue.* = try zclip.ClipQueue.init(
        io,
        self.init_arena.allocator(),
        .{ .buffer_size = 5 },
    );

    const backend = try Backend.init(
        io,
        &self.init_arena,
        read_clip_queue,
    );

    const commands_in_buf = try self.init_arena.allocator().alloc(
        Command,
        config.commands_in_buf_size,
    );

    const commands_in = try self.init_arena.allocator().create(CommandQueue);

    commands_in.* = CommandQueue.init(commands_in_buf);

    self.alloc = alloc;
    self.io = io;
    self.backend = backend;
    self.commands_in = commands_in;
    self.worker = undefined;
    self.clips = try std.ArrayList(Clip).initCapacity(
        self.alloc,
        config.clips_buf_size_max,
    );
    self.on_clipboard = null;
    self.userdata = null;

    const worker_ctx = try self.init_arena.allocator().create(WorkerContext);
    worker_ctx.* = .{
        .in = commands_in,
        .clip_queue = read_clip_queue,
        .io = io,
        .alloc = self.init_arena.allocator(),
        .backend = backend,
    };

    self.worker = try io.concurrent(workerFn, .{ self, worker_ctx });

    return self;
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
    /// A bounded number of clips to hold before removing oldest entries.
    clips_buf_size_max: usize = 100,
};
