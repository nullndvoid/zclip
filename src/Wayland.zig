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

/// Stub function, to be overwritten by caller after `.init`.
fn default_on_read(_: Clip, _: *anyopaque) void {}

/// Passed into `DataControlDevice` listeners.
const ListenerContext = struct {
    /// This is actually wrapped in an `ArenaAllocator` in `init`.
    /// i.e. there's no need to free anything we allocate in the
    /// listener.
    alloc: Allocator,
    io: Io,
    current_mime: Mime,
    /// A callback ran on read.
    on_read: *const fn (clip: Clip, userdata: *anyopaque) void = default_on_read,
    /// Passed into `on_read`.
    userdata: *anyopaque,
};

pub fn init(io: Io, arena: *std.heap.ArenaAllocator) !Wayland {
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

    var listener_ctx = try arena.allocator().create(ListenerContext);
    listener_ctx.alloc = arena.allocator();
    listener_ctx.io = io;
    listener_ctx.current_mime = try .init(arena.allocator(), 16);

    switch (dev) {
        // TODO: Possibly use const fn pointers to set callbacks for clipboard updates?
        //       Might be simpler to Queue them and pull entries from the queue
        //       on the frontend? See pkg wayland.zig, grep for `HandlerFn` if using callbacks.
        .Ext => |ext| {
            ext.setListener(*ListenerContext, Ext.listener, listener_ctx);
        },
    }

    return .{
        .arena = arena,
        .display = display,
        .registry = reg,
        .seat = seat,
        .dcm = dcm,
        .dev = dev,
        .listener_ctx = listener_ctx,
    };
}

pub fn setOnRead(self: *Wayland, comptime T: type, comptime callback: *const fn (clip: Clip, userdata: *T) void, userdata: *T) void {
    self.listener_ctx.on_read = @ptrCast(@alignCast(callback));
    self.listener_ctx.userdata = @ptrCast(userdata);
}

pub fn deinit(self: Wayland) void {
    self.dev.destroy();
    self.dcm.destroy();

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
};

const DataControlSource = union(enum) {
    Ext: *Ext.Source,
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

    fn dataOfferListener(_: *Offer, event: Offer.Event, ctx: *ListenerContext) void {
        switch (event) {
            .offer => |offer| {
                const mime_type: [:0]const u8 = std.mem.span(offer.mime_type);

                std.log.debug("Got MIME type: {s}", .{mime_type});

                ctx.current_mime.append(mime_type) catch |err| {
                    std.log.err("Could not append to MIME type list: {t}. Was capacity exceeded?", .{err});
                    // return;
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

                const ask_for = userdata.current_mime.choose() orelse "text/plain;charset=utf-8";

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
                _ = std.c.close(write_fd);

                var reader_buf: [pipe_buf_size]u8 = undefined;

                // Now read the contents until EOF.
                var file_rdr = file.readerStreaming(userdata.io, &reader_buf);
                const rdr = &file_rdr.interface;

                // Nevermind the segfault is in the reader.
                const data = rdr.allocRemaining(userdata.alloc, .unlimited) catch |err| {
                    std.log.err("Ext.listener: couldn't allocate memory for clipboard contents. {t}. Some data may be lost.", .{err});
                    return;
                };

                // TODO: Execute a callback with read Clip.
                userdata.on_read(Clip{
                    .data = data,
                    .mime_type = ask_for,
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

test "init/deinit" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var backend = try Wayland.init(io, &arena);
    defer backend.deinit();

    // Segfault originates on call of callback. Investigate later.
    backend.setOnRead(void, test_on_read, @constCast(&{}));

    while (backend.display.dispatch() == .SUCCESS) {}
}

fn test_on_read(clip: Clip, _: *void) void {
    if (std.mem.eql(u8, clip.mime_type, "text/plain;charset=utf-8")) {
        std.log.debug("test_on_read got clip: {s}", .{clip.data});
    } else {
        std.log.debug("test_on_read got clip ({s})", .{clip.mime_type});
    }
}
