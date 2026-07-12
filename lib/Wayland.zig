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

//! Wayland interface for clipboard management. Call init before you do anything else.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const wayland = @import("wayland").client;
const wl = wayland.wl;
const Display = wl.Display;
const Registry = wl.Registry;
const Seat = wl.Seat;

const Clip = @import("Clip.zig");
const ClipQueue = @import("root.zig").ClipQueue;
const Mime = @import("Mime.zig");

const Wayland = @This();

const log = std.log.scoped(.WaylandBackend);

arena: *std.heap.ArenaAllocator,

display: *Display,
registry: *Registry,
seat: *Seat,
dcm: DataControlManager,
dev: DataControlDevice,

/// Stored for later deallocation.
listener_ctx: *ListenerContext,

/// Should stop, set when event loop should stop, atomic bool.
should_stop: std.atomic.Value(bool) = .{ .raw = false },

/// Awaited upon stop signal. Returns nothing but logs errors if needed.
event_loop_future: ?std.Io.Future(void) = null,

/// Passed into `DataControlDevice` listeners.
const ListenerContext = struct {
    /// A real (non-arena) allocator. Clip payloads pushed into `clip_queue`
    /// (ownership transfers to the consumer) and our pending write copy in
    /// `clip_to_write` are allocated from it.
    clip_alloc: Allocator,
    io: Io,
    /// Needed so the listener can flush queued requests (e.g. `receive`) to
    /// the compositor mid-callback, before we block reading the pipe.
    display: *Display,
    current_mime: Mime,
    /// Guards `clip_to_write` and `current_source`: `setClipboard` runs on
    /// the clipboard worker while the data source listener runs on the
    /// event loop task.
    write_lock: Io.Mutex = .init,
    /// Our copy of the pending write, served on every `.send`. Freed on
    /// replacement, on `.cancelled` and on deinit.
    clip_to_write: ?Clip,
    /// The source registered as the current selection. Destroyed on
    /// `.cancelled`.
    current_source: ?DataControlSource = null,
    /// Cleaned up on deinit. A group of pending and completed reads.
    pending_reads: Io.Group,
    /// Passed in from `Clipboard`. Written to when the system sees new entries.
    clip_queue: *ClipQueue,

    /// Caller must hold `write_lock`.
    fn freeClipToWriteLocked(self: *ListenerContext) void {
        if (self.clip_to_write) |clip| {
            self.clip_alloc.free(clip.data);
            self.clip_alloc.free(clip.mime_type);
        }
        self.clip_to_write = null;
    }
};

/// This backend is heap allocated so the event loop thread works. You are responsible for calling `deinit`
/// on this (before you deinit the arena).
///
/// `clip_alloc` allocates the clip payloads handed over via `clip_queue`;
/// whoever consumes the queue owns and frees them.
pub fn init(io: Io, arena: *std.heap.ArenaAllocator, clip_alloc: Allocator, clip_queue: *ClipQueue) !*Wayland {
    const display = try Display.connect(null);
    var reg = try display.getRegistry();
    var globals = Globals{};

    reg.setListener(*Globals, registryListener, &globals);

    const ret = display.roundtrip();
    if (ret != .SUCCESS) return error.RoundtripFailed;

    // This might fire on compositors using old wlroots but I will not implement Zwlr support yet.
    if (globals.ext_dc_manager == null or globals.seat == null) return error.MissingGlobals;

    const seat = globals.seat.?;

    // TODO: Support deprecated zwlr_data_control_manager_v1.
    var dcm = DataControlManager{
        .Ext = globals.ext_dc_manager.?,
    };

    const dev = try dcm.getDataDevice(seat);

    const listener_ctx = try arena.allocator().create(ListenerContext);

    listener_ctx.* = .{
        .clip_alloc = clip_alloc,
        .io = io,
        .display = display,
        // TODO: Make this queue size configurable. i.e. pass a WaylandConfig struct.
        .current_mime = try .init(arena.allocator(), 16),
        .clip_to_write = null,
        .current_source = null,
        .pending_reads = .init,
        .clip_queue = clip_queue,
    };

    switch (dev) {
        .Ext => |ext| {
            ext.setListener(*ListenerContext, Ext.listener, listener_ctx);
        },
    }

    // Annoyingly we need to heap allocate ourselves to call eventLoop lol.
    var self = try arena.allocator().create(Wayland);

    self.* = .{
        .arena = arena,
        .display = display,
        .registry = reg,
        .seat = seat,
        .dcm = dcm,
        .dev = dev,
        .listener_ctx = listener_ctx,
        .should_stop = .{ .raw = false },
    };

    // Now we can await this after setting the stop signal.
    self.event_loop_future = try self.listener_ctx.io.concurrent(Wayland.eventLoop, .{self});

    return self;
}

/// Creates a data source offering the clip's MIME type. The caller
/// registers it as the selection.
///
/// TODO: Handle offering a range of MIME types, maybe make `Clip.mime_type` a list?
fn createDataOffer(self: *Wayland, clip: Clip) !DataControlSource {
    const source = try self.dcm.createDataSource();
    errdefer source.destroy();

    // libwayland copies request arguments during marshalling, so this
    // sentinel-terminated copy only needs to live for the `offer` call.
    const mime_type = try self.listener_ctx.clip_alloc.dupeSentinel(u8, clip.mime_type, 0);
    defer self.listener_ctx.clip_alloc.free(mime_type);

    source.offer(mime_type);
    // To avoid reading back our own entries later on and deadlocking.
    source.offer(Mime.self_marker);

    return source;
}

/// TODO: If an input MIME type is specific but not text, offer it multiple times as
///       e.g. text/html, text/plain;charset=utf-8.
///
///       This could mean building a list of MIME types to offer for a given input.
pub fn setClipboard(self: *Wayland, clip: Clip) !void {
    const ctx = self.listener_ctx;

    // Copied because the compositor requests the data via `.send` events
    // for as long as we own the selection, long after this call returns.
    // Once ownership is handed to `clip_to_write` a later failure (flush)
    // must not free the copies: the selection request is already queued.
    var handed_off = false;
    const clip_data = try ctx.clip_alloc.dupe(u8, clip.data);
    errdefer if (!handed_off) ctx.clip_alloc.free(clip_data);
    const mime_type = try ctx.clip_alloc.dupe(u8, clip.mime_type);
    errdefer if (!handed_off) ctx.clip_alloc.free(mime_type);

    {
        ctx.write_lock.lockUncancelable(ctx.io);
        defer ctx.write_lock.unlock(ctx.io);

        const source = try self.createDataOffer(clip);

        // The previous write can no longer be requested once the new
        // source is the selection; its source is destroyed when the
        // compositor cancels it.
        ctx.freeClipToWriteLocked();
        ctx.clip_to_write = .{
            .data = clip_data,
            .is_text = clip.is_text,
            .mime_type = mime_type,
        };
        handed_off = true;
        ctx.current_source = source;

        // Listen for `.send` before the selection request can reach the
        // compositor.
        source.send(ctx);
        self.dev.setSelection(source);
    }

    const flush_res = self.display.flush();
    if (flush_res != .SUCCESS) {
        log.debug("Failed to flush wayland display: {t}", .{flush_res});
        return error.DisplayFlushFailed;
    }
}

pub fn deinit(self: *Wayland) void {
    self.should_stop.store(true, .release);
    if (self.event_loop_future) |*future| {
        future.await(self.listener_ctx.io);
    }

    // Drain any pending reads.
    self.listener_ctx.pending_reads.await(self.listener_ctx.io) catch {};

    if (self.listener_ctx.current_source) |*src| {
        src.destroy();
    }

    self.listener_ctx.write_lock.lockUncancelable(self.listener_ctx.io);
    self.listener_ctx.freeClipToWriteLocked();
    self.listener_ctx.write_lock.unlock(self.listener_ctx.io);

    self.listener_ctx.clip_queue.deinit(self.arena.allocator());

    self.dev.destroy();
    self.dcm.destroy();

    self.seat.destroy();

    self.registry.destroy();
    self.display.disconnect();
}

const DataControlDevice = union(enum) {
    Ext: *Ext.Device,

    pub inline fn destroy(self: DataControlDevice) void {
        switch (self) {
            .Ext => |dev| {
                dev.destroy();
            },
        }
    }

    pub inline fn setSelection(self: DataControlDevice, src: DataControlSource) void {
        switch (self) {
            .Ext => |dev| {
                dev.setSelection(src.Ext);
            },
        }
    }
};

const DataControlSource = union(enum) {
    Ext: *Ext.Source,

    /// Note this can be called as many times as clip MIME types offered.
    pub inline fn offer(self: DataControlSource, mime_type: [:0]const u8) void {
        switch (self) {
            .Ext => |src| {
                src.offer(mime_type);
            },
        }
    }

    pub inline fn destroy(self: DataControlSource) void {
        switch (self) {
            .Ext => |src| {
                src.destroy();
            },
        }
    }

    pub inline fn send(self: DataControlSource, ctx: *ListenerContext) void {
        switch (self) {
            .Ext => |src| {
                src.setListener(*ListenerContext, Ext.dataSourceListener, ctx);
            },
        }
    }
};

const DataControlManager = union(enum) {
    Ext: *Ext.Manager,

    pub inline fn destroy(self: DataControlManager) void {
        switch (self) {
            .Ext => |mgr| {
                mgr.destroy();
            },
        }
    }

    pub inline fn getDataDevice(self: DataControlManager, seat: *Seat) !DataControlDevice {
        switch (self) {
            .Ext => |mgr| {
                const device = try mgr.getDataDevice(seat);
                return .{ .Ext = device };
            },
        }
    }

    pub inline fn createDataSource(self: DataControlManager) !DataControlSource {
        switch (self) {
            .Ext => |mgr| {
                const source = try mgr.createDataSource();
                return .{ .Ext = source };
            },
        }
    }
};

/// Used for `registryListener` when we need compositor globals.
const Globals = struct {
    ext_dc_manager: ?*Ext.Manager = null,
    seat: ?*Seat = null,
};

/// Linux sets this to 4096. I figured we can have a streaming reader with this
/// bufsize. See the manpage pipe(7).
const pipe_buf_size = 4096;

/// Handles the `ext_data_control` protocol. I will support deprecated zwlr
/// later if need be. Should contain event handlers.
const Ext = struct {
    pub const Manager = wayland.ext.DataControlManagerV1;
    pub const Device = wayland.ext.DataControlDeviceV1;
    pub const Source = wayland.ext.DataControlSourceV1;
    pub const Offer = wayland.ext.DataControlOfferV1;

    fn dataSourceListener(source: *Source, ev: Source.Event, ctx: *ListenerContext) void {
        switch (ev) {
            .send => |snd| {
                const write_file = std.Io.File{
                    .handle = snd.fd,
                    .flags = .{ .nonblocking = false },
                };
                defer write_file.close(ctx.io);

                // Held for the whole write so a concurrent `setClipboard`
                // cannot free the data from under us.
                ctx.write_lock.lockUncancelable(ctx.io);
                defer ctx.write_lock.unlock(ctx.io);

                const clip = ctx.clip_to_write orelse {
                    log.err("Tried to send clip but it was null!", .{});
                    return;
                };

                write_file.writeStreamingAll(ctx.io, clip.data) catch |err| {
                    log.err(
                        "Failed writing {d} bytes to clipboard. Reason: {t}",
                        .{ clip.data.len, err },
                    );

                    return;
                };
            },
            .cancelled => {
                ctx.write_lock.lockUncancelable(ctx.io);
                defer ctx.write_lock.unlock(ctx.io);

                // A cancelled source is never asked to send again, so it is
                // destroyed either way. It may be a source we already
                // replaced though, in which case the current selection's
                // state must be left alone.
                const is_current = if (ctx.current_source) |cur| switch (cur) {
                    .Ext => |src| src == source,
                } else false;

                source.destroy();

                if (is_current) {
                    ctx.current_source = null;
                    ctx.freeClipToWriteLocked();
                }
            },
        }
    }

    /// TODO: Check this does not fire on primary_selection until this is implemented.
    ///       If so we want to reset current_mime on primary_selections.
    fn dataOfferListener(_: *Offer, event: Offer.Event, ctx: *ListenerContext) void {
        switch (event) {
            .offer => |offer| {
                const mime_type: [:0]const u8 = std.mem.span(offer.mime_type);

                ctx.current_mime.append(mime_type) catch |err| {
                    log.err("Could not append to MIME type list: {t}. Was capacity exceeded?", .{err});
                };
            },
        }
    }

    pub fn listener(_: *Device, event: Device.Event, userdata: *ListenerContext) void {
        switch (event) {
            .data_offer => |off| {
                off.id.setListener(*ListenerContext, dataOfferListener, userdata);
            },
            .selection => |sel| {
                // Since selection fires after all of the data_offer events,
                // we have collected all the MIME types.
                defer userdata.current_mime.reset();

                const offer = sel.id orelse {
                    log.debug("Got null data control offer. Returning.", .{});
                    return;
                };

                // The protocol requires the previous selection offer to be destroyed
                // by the time the next `selection` event arrives. We only ever need
                // an offer for the duration of this callback, so destroy it as soon
                // as we're done with it rather than tracking a "previous" pointer.
                defer offer.destroy();

                // To avoid deadlocks when we end up reading and writing a pipe in the same process.
                // It is also quite unneccessary to read back what we wrote in any case.
                if (userdata.current_mime.from_zclip) return;

                const ask_for = userdata.current_mime.choose() orelse "text/plain;charset=utf-8";
                const is_text = Mime.isPlainText(ask_for);

                var fds: [2]i32 = @splat(0);
                if (std.c.pipe(&fds) == -1) {
                    log.err("Ext.listener failed to create pipe. Some data may be lost.", .{});
                    return;
                }

                const read_fd = fds[0];

                const write_fd = fds[1];

                offer.receive(ask_for, write_fd);

                const flush_ret = userdata.display.flush();
                if (flush_ret != .SUCCESS) {
                    log.err("Ext.listener failed to flush receive request: {t}. Some data may be lost.", .{flush_ret});
                    _ = std.c.close(write_fd);
                    _ = std.c.close(read_fd);
                    return;
                }

                _ = std.c.close(write_fd);

                // Becomes the queued clip's mime_type; the queue consumer
                // owns and frees it.
                const mime_copy = userdata.clip_alloc.dupe(u8, ask_for) catch {
                    log.err(
                        "could not dupe current_mime in selection listener. Returning!",
                        .{},
                    );

                    _ = std.c.close(read_fd);
                    return;
                };

                userdata.pending_reads.concurrent(
                    userdata.io,
                    readClip,
                    .{ read_fd, userdata, mime_copy, is_text },
                ) catch unreachable;
            },
            // For now we ignore these.
            .primary_selection => {},
            // TODO: Handle this. And also signal handlers.
            .finished => {
                userdata.current_mime.deinit();
            },
        }
    }

    fn readClip(read_fd: i32, userdata: *ListenerContext, mime_type: []const u8, is_text: bool) void {
        var reader_buf: [pipe_buf_size]u8 = undefined;

        const file = std.Io.File{
            .handle = read_fd,
            .flags = .{ .nonblocking = false },
        };
        defer file.close(userdata.io);

        // Now read the contents until EOF.
        var file_rdr = file.readerStreaming(userdata.io, &reader_buf);
        const rdr = &file_rdr.interface;

        const data = rdr.allocRemaining(userdata.clip_alloc, .unlimited) catch |err| {
            log.err("Ext.listener: couldn't allocate memory for clipboard contents. {t}. Some data may be lost.", .{err});
            userdata.clip_alloc.free(mime_type);
            return;
        };

        userdata.clip_queue.queue.putOneUncancelable(userdata.io, .{
            .data = data,
            .mime_type = mime_type,
            .is_text = is_text,
        }) catch |err| switch (err) {
            error.Closed => {
                log.info("Clip queue was closed. Some data will be lost.", .{});
                userdata.clip_alloc.free(data);
                userdata.clip_alloc.free(mime_type);
            },
        };
    }
};

/// See doc comment on `Ext`. Not yet implemented.
const Zwlr = struct {};

fn registryListener(reg: *Registry, event: Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |ev| {
            if (std.mem.orderZ(u8, ev.interface, Ext.Manager.interface.name) == .eq) {
                globals.ext_dc_manager = reg.bind(ev.name, Ext.Manager, 1) catch return;
            } else if (std.mem.orderZ(u8, ev.interface, Seat.interface.name) == .eq) {
                globals.seat = reg.bind(ev.name, Seat, 1) catch return;
            } else return;

            log.debug("Compositor gave us global {s}", .{ev.interface});
        },
        .global_remove => {},
    }
}

fn eventLoop(self: *Wayland) void {
    const display_fd = self.display.getFd();
    var fds = [_]std.c.pollfd{
        .{
            .fd = display_fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        },
    };
    const poll_timeout_ms = 200;

    while (!self.should_stop.load(.acquire)) {
        // Flush queued requests before we block.
        const flush_res = self.display.flush();
        if (flush_res != .SUCCESS) {
            log.err("could not flush display: {t}", .{flush_res});
        }

        const ret = std.c.poll(fds[0..].ptr, 1, poll_timeout_ms);
        if (ret < 0) {
            // We should retry on EINTR.
            if (std.posix.errno(ret) == .INTR) continue;
            log.err("poll failed, stopping event loop.", .{});
            break;
        }

        // On timeout, check if we should stop.
        if (ret == 0) continue;

        if (fds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR) != 0) {
            log.debug("display fd closed, stopping event loop.", .{});
            break;
        }

        if (fds[0].revents & std.c.POLL.IN != 0) {
            const dispatch_res = self.display.dispatch();
            if (dispatch_res != .SUCCESS) {
                log.err("dispatch error {t}, stopping.", .{dispatch_res});
                break;
            }
        }
    }
}

/// Reads from the system clipboard with wl-paste. Useful for unit testing.
/// Caller should free Clip.data.
fn readClipboardWlPaste(io: Io, alloc: Allocator) !Clip {
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "wl-paste",
            "--no-newline",
        },
        .cwd = .inherit,
        .stdout = .pipe,
    });

    var stdout = child.stdout.?;
    var buf: [1024]u8 = undefined;
    var stdout_reader = stdout.readerStreaming(io, &buf);
    var rdr = &stdout_reader.interface;

    const data = try rdr.allocRemaining(alloc, .unlimited);

    const term = try child.wait(io);

    if (term.exited != 0) return error.WlPasteFailed;

    // For now just assume we have text.
    return Clip{
        .data = data,
        .is_text = true,
        .mime_type = "text/plain;charset=utf-8",
    };
}

/// Writes to the system clipboard with wl-copy. Useful for unit testing.
fn writeClipboardWlCopy(io: Io, clip: Clip) !void {
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "wl-copy",
            "--type",
            clip.mime_type,
        },
        .cwd = .inherit,
        .stdin = .pipe,
    });

    var stdin = child.stdin.?;
    try stdin.writeStreamingAll(io, clip.data);

    stdin.close(io);
    // Else we attempt to close the pipe twice.
    child.stdin = null;

    const term = try child.wait(io);

    if (term.exited != 0) return error.WlCopyFailed;
}

test "read clipboard -- wl-clipboard" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var clip_queue = try ClipQueue.init(io, arena.allocator(), .{});
    defer clip_queue.deinit(arena.allocator());

    var backend = try Wayland.init(io, &arena, alloc, &clip_queue);
    defer backend.deinit();

    const clip_data = "This is some text";

    try writeClipboardWlCopy(io, .{
        .data = clip_data,
        .is_text = true,
        .mime_type = "text/plain;charset=utf-8",
    });

    try io.sleep(.fromMilliseconds(10), .real);

    clip_queue.close();

    // Sometimes we get a stale entry on init of the backend,
    // so we take the tail of the queue.
    var clips: [2]Clip = undefined;
    const nclips = try clip_queue.queue.get(io, &clips, 1);
    defer for (clips[0..nclips]) |clip| {
        alloc.free(clip.data);
        alloc.free(clip.mime_type);
    };

    try std.testing.expectEqualSlices(u8, clip_data, clips[nclips - 1].data);
}

test "write clipboard -- wl-clipboard" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var clip_queue = try ClipQueue.init(io, arena.allocator(), .{});
    defer clip_queue.deinit(arena.allocator());

    var backend = try Wayland.init(io, &arena, alloc, &clip_queue);
    defer backend.deinit();

    const clip_data = "This is some text";
    try backend.setClipboard(
        .{
            .data = clip_data,
            .is_text = true,
            .mime_type = "text/plain;charset=utf-8",
        },
    );

    try io.sleep(.fromMilliseconds(10), .real);

    const clip = try readClipboardWlPaste(io, arena.allocator());

    try std.testing.expectEqualSlices(u8, clip_data, clip.data);

    // Write again: replaces the pending copy and cancels the first source.
    const clip_data2 = "Some different text";
    try backend.setClipboard(
        .{
            .data = clip_data2,
            .is_text = true,
            .mime_type = "text/plain;charset=utf-8",
        },
    );

    try io.sleep(.fromMilliseconds(10), .real);

    const clip2 = try readClipboardWlPaste(io, arena.allocator());

    try std.testing.expectEqualSlices(u8, clip_data2, clip2.data);

    // The backend may have picked up a stale selection on init; free any
    // queued payloads since they are owned by us, not the arena.
    clip_queue.close();
    var stale_clips: [2]Clip = undefined;
    const nstale = clip_queue.queue.get(io, &stale_clips, 1) catch 0;
    for (stale_clips[0..nstale]) |stale| {
        alloc.free(stale.data);
        alloc.free(stale.mime_type);
    }
}
