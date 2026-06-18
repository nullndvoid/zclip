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
const Mime = @import("Mime.zig");

const Wayland = @This();

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

/// Stub function, to be overwritten by caller after `.init`.
fn default_on_read(_: Clip, _: *anyopaque) void {}

/// Passed into `DataControlDevice` listeners.
const ListenerContext = struct {
    /// This is actually wrapped in an `ArenaAllocator` in `init`.
    /// i.e. there's no need to free anything we allocate in the
    /// listener.
    alloc: Allocator,
    io: Io,
    /// Needed so the listener can flush queued requests (e.g. `receive`) to
    /// the compositor mid-callback, before we block reading the pipe.
    display: *Display,
    current_mime: Mime,
    /// A callback ran on read.
    on_read: *const fn (clip: Clip, userdata: *anyopaque) void,
    /// Passed into `on_read`.
    userdata: *anyopaque,
    /// Nulled on `.cancelled` event.
    clip_to_write: ?*const Clip,
    /// Destroyed after we wrote to the clipboard.
    current_source: ?DataControlSource = null,
};

/// This backend is heap allocated so the event loop thread works. You are responsible for calling `deinit`
/// on this (before you deinit the arena).
pub fn init(io: Io, arena: *std.heap.ArenaAllocator) !*Wayland {
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
        .alloc = arena.allocator(),
        .io = io,
        .display = display,
        // TODO: Make this queue size configurable. i.e. pass a WaylandConfig struct.
        .current_mime = try .init(arena.allocator(), 16),
        .on_read = default_on_read,
        .userdata = undefined,
        .clip_to_write = null,
        .current_source = null,
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

/// TODO: Handle offering a range of MIME types, maybe make `Clip.mime_type` a list?
///       Or handle this elsewhere using `listener_ctx.current_source`.
fn createDataOffer(self: *Wayland, clip: *const Clip) !void {
    const source = try self.dcm.createDataSource();

    source.offer(clip.mime_type);
    // To avoid reading back our own entries later on and deadlocking.
    source.offer(Mime.self_marker);

    self.listener_ctx.current_source = source;
}

/// TODO: If an input MIME type is specific but not text, offer it multiple times as
///       e.g. text/html, text/plain;charset=utf-8.
///
///       This could mean building a list of MIME types to offer for a given input.
pub fn setClipboard(self: *Wayland, clip: Clip) !void {
    const clip_copy = try self.arena.allocator().create(Clip);
    clip_copy.* = clip;

    try self.createDataOffer(clip_copy);
    if (self.listener_ctx.current_source) |src| {
        self.dev.setSelection(src);
        self.listener_ctx.clip_to_write = clip_copy;
        src.send(self.listener_ctx);
    }

    const flush_res = self.display.flush();
    if (flush_res != .SUCCESS) {
        std.log.debug("Failed to flush wayland display: {t}", .{flush_res});
        return error.DisplayFlushFailed;
    }
}

pub fn setOnRead(self: *Wayland, comptime T: type, comptime callback: *const fn (clip: Clip, userdata: *T) void, userdata: *T) void {
    self.listener_ctx.on_read = @ptrCast(@alignCast(callback));
    self.listener_ctx.userdata = @ptrCast(userdata);
}

pub fn deinit(self: *Wayland) void {
    self.should_stop.store(true, .release);
    if (self.event_loop_future) |*future| {
        future.await(self.listener_ctx.io);
    }

    if (self.listener_ctx.current_source) |*src| {
        src.destroy();
    }

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

    fn dataSourceListener(_: *Source, ev: Source.Event, ctx: *ListenerContext) void {
        switch (ev) {
            .send => |snd| {
                if (ctx.clip_to_write == null) {
                    std.log.err("Tried to send clip but it was null!", .{});
                    return;
                }

                const clip = ctx.clip_to_write.?;

                const write_fd = snd.fd;
                const write_file = std.Io.File{
                    .handle = write_fd,
                    .flags = .{ .nonblocking = false },
                };
                defer write_file.close(ctx.io);

                write_file.writeStreamingAll(ctx.io, clip.data) catch |err| {
                    std.log.err(
                        "Failed writing {d} bytes to clipboard. Reason: {t}",
                        .{ clip.data.len, err },
                    );

                    return;
                };
            },
            .cancelled => {
                if (ctx.current_source) |src| {
                    src.destroy();
                }
                ctx.current_source = null;
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
                    std.log.err("Could not append to MIME type list: {t}. Was capacity exceeded?", .{err});
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
                    std.log.debug("Got null data control offer. Returning.", .{});
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
                    std.log.err("Ext.listener failed to create pipe. Some data may be lost.", .{});
                    return;
                }

                const read_fd = fds[0];
                const file = std.Io.File{
                    .handle = read_fd,
                    .flags = .{ .nonblocking = false },
                };
                defer file.close(userdata.io);

                const write_fd = fds[1];

                offer.receive(ask_for, write_fd);

                const flush_ret = userdata.display.flush();
                if (flush_ret != .SUCCESS) {
                    std.log.err("Ext.listener failed to flush receive request: {t}. Some data may be lost.", .{flush_ret});
                    _ = std.c.close(write_fd);
                    return;
                }

                _ = std.c.close(write_fd);

                var reader_buf: [pipe_buf_size]u8 = undefined;

                // Now read the contents until EOF.
                var file_rdr = file.readerStreaming(userdata.io, &reader_buf);
                const rdr = &file_rdr.interface;

                const data = rdr.allocRemaining(userdata.alloc, .unlimited) catch |err| {
                    std.log.err("Ext.listener: couldn't allocate memory for clipboard contents. {t}. Some data may be lost.", .{err});
                    return;
                };

                userdata.on_read(Clip{
                    .data = data,
                    .mime_type = ask_for,
                    .is_text = is_text,
                }, userdata.userdata);
            },
            // For now we ignore these.
            .primary_selection => {},
            // TODO: Handle this. And also signal handlers.
            .finished => {
                userdata.current_mime.deinit();
            },
        }
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

            std.log.debug("Compositor gave us global {s}", .{ev.interface});
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
            std.log.err("Wayland backend: could not flush display: {t}", .{flush_res});
        }

        const ret = std.c.poll(fds[0..].ptr, 1, poll_timeout_ms);
        if (ret < 0) {
            // We should retry on EINTR.
            if (std.posix.errno(ret) == .INTR) continue;
            std.log.err("Wayland backend: poll failed, stopping event loop.", .{});
            break;
        }

        // On timeout, check if we should stop.
        if (ret == 0) continue;

        if (fds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR) != 0) {
            std.log.debug("Wayland backend: display fd closed, stopping event loop.", .{});
            break;
        }

        if (fds[0].revents & std.c.POLL.IN != 0) {
            const dispatch_res = self.display.dispatch();
            if (dispatch_res != .SUCCESS) {
                std.log.err("Wayland backend: dispatch error {t}, stopping.", .{dispatch_res});
                break;
            }
        }
    }
}
