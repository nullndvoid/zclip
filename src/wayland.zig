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
const c = std.c;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const Registry = wl.Registry;
const Event = Registry.Event;
const Display = wl.Display;
const Seat = wl.Seat;

const Clipboard = @import("clipboard.zig");
const Clipping = @import("clipping.zig");
const ext = @import("protocols/ext.zig");
const zwlr = @import("protocols/zwlr.zig");

const WaylandBackend = @This();

display: *Display,
registry: *Registry,
dcm: DataControlManager,
seat: *Seat,
io: Io,
alloc: Allocator,
dev: DataControlDevice,
/// Eventfd written to by `deinit` to wake the event loop out of its poll.
wake_fd: posix.fd_t,
event_loop: Io.Future(EventLoopError!void),
// Event loop writes to this queue and is read by the `Clipboard`.
read_queue: Io.Queue(Clipping),
read_queue_clip_buf: []Clipping,

const Globals = struct {
    ext_dcm: ?*ext.Manager = null,
    zwlr_dcm: ?*zwlr.Manager = null,
    seat: ?*Seat = null,
};

var globals: Globals = .{};

const DataControlManager = union(enum) {
    ext: *ext.Manager,
    zwlr: *zwlr.Manager,
};

const DataControlSource = union(enum) {
    ext: *ext.Source,
    zwlr: *zwlr.Source,
};

const DataControlDevice = union(enum) {
    ext: *ext.Device,
    zwlr: *zwlr.Device,
};

fn regListener(reg: *Registry, ev: Event, userdata: *Globals) void {
    switch (ev) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, ext.Manager.interface.name) == .eq) {
                userdata.ext_dcm = reg.bind(global.name, ext.Manager, 1) catch return;
                std.log.debug("Bound ExtDataControlManager V1 to globals.", .{});
            } else if (std.mem.orderZ(u8, global.interface, zwlr.Manager.interface.name) == .eq) {
                userdata.zwlr_dcm = reg.bind(global.name, zwlr.Manager, 1) catch return;
                std.log.debug("Bound ZwlrDataControlManager V1 to globals.", .{});
            } else if (std.mem.orderZ(u8, global.interface, Seat.interface.name) == .eq) {
                userdata.seat = reg.bind(global.name, Seat, 1) catch return;
                std.log.debug("Got wl_seat from compositor.", .{});
            }
        },
        .global_remove => {},
    }
}

pub const EventLoopError = posix.PollError || error{
    DispatchFailed,
    FlushFailed,
    ReadFailed,
    DisplayClosed,
};

/// Runs as an `Io.concurrent` task: sleeps in poll on the display socket and
/// `wake_fd`, then reads and dispatches compositor events. Listener callbacks
/// run on this task.
fn runEventLoop(self: *WaylandBackend) EventLoopError!void {
    const display_fd = self.display.getFd();

    while (true) {
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }

        switch (self.display.flush()) {
            .SUCCESS, .AGAIN => {},
            else => {
                self.display.cancelRead();
                return error.FlushFailed;
            },
        }

        var fds = [_]posix.pollfd{
            .{ .fd = display_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        _ = posix.poll(&fds, -1) catch |err| {
            self.display.cancelRead();
            return err;
        };

        if (fds[1].revents != 0) {
            self.display.cancelRead();
            return;
        }

        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
            self.display.cancelRead();
            return error.DisplayClosed;
        }

        if (fds[0].revents & posix.POLL.IN == 0) {
            self.display.cancelRead();
            continue;
        }

        if (self.display.readEvents() != .SUCCESS) return error.ReadFailed;
        if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    }
}

pub fn init(io: Io, alloc: Allocator) !*WaylandBackend {
    const backend = try alloc.create(WaylandBackend);
    errdefer alloc.destroy(backend);

    const wake_fd = c.eventfd(0, std.os.linux.EFD.CLOEXEC);
    if (wake_fd == -1) return error.EventFdFailed;
    errdefer _ = c.close(wake_fd);

    const display = try Display.connect(null);
    const registry = try display.getRegistry();

    registry.setListener(*Globals, regListener, &globals);
    const res = display.roundtrip();

    if (res != .SUCCESS) {
        return error.RoundTripFailed;
    }

    var dcm: ?DataControlManager = null;

    if (globals.ext_dcm) |ext_mgr| {
        dcm = .{ .ext = ext_mgr };
    } else if (globals.zwlr_dcm) |zwlr_mgr| {
        dcm = .{ .zwlr = zwlr_mgr };
    }

    const seat = globals.seat.?;
    const data_dev = try getDataDevice(dcm.?, seat);

    const read_queue_clip_buf = try alloc.alloc(Clipping, 5);

    backend.* = .{
        .display = display,
        .registry = registry,
        .dcm = dcm.?,
        .seat = seat,
        .io = io,
        .dev = data_dev,
        .alloc = alloc,
        .wake_fd = wake_fd,
        .event_loop = undefined,
        .read_queue_clip_buf = read_queue_clip_buf,
        .read_queue = .init(read_queue_clip_buf),
    };

    backend.setDataDeviceListener();
    backend.event_loop = try io.concurrent(runEventLoop, .{backend});

    return backend;
}

pub fn deinit(self: *WaylandBackend) void {
    // Wake the event loop and wait for it to exit before destroying the
    // objects it dispatches on.
    const wake: u64 = 1;
    _ = c.write(self.wake_fd, std.mem.asBytes(&wake), @sizeOf(u64));
    self.event_loop.await(self.io) catch |err| {
        std.log.err("Wayland event loop exited with {t}.", .{err});
    };
    _ = c.close(self.wake_fd);

    if (globals.ext_dcm) |ext_mgr| {
        ext_mgr.destroy();
    }

    if (globals.zwlr_dcm) |zwlr_mgr| {
        zwlr_mgr.destroy();
    }

    self.registry.destroy();
    self.display.disconnect();
    self.alloc.free(self.read_queue_clip_buf);
    self.alloc.destroy(self);
}

fn createDataSource(self: *WaylandBackend) !DataControlSource {
    return switch (self.dcm) {
        .ext => .{ .ext = try self.dcm.ext.createDataSource() },
        .zwlr => .{ .zwlr = try self.dcm.zwlr.createDataSource() },
    };
}

fn getDataDevice(dcm: DataControlManager, seat: *Seat) !DataControlDevice {
    return switch (dcm) {
        .ext => .{ .ext = try dcm.ext.getDataDevice(seat) },
        .zwlr => .{ .zwlr = try dcm.zwlr.getDataDevice(seat) },
    };
}

fn setDataDeviceListener(self: *WaylandBackend) void {
    switch (self.dev) {
        .ext => self.dev.ext.setListener(*WaylandBackend, ext.dataControlDeviceListener, self),
        .zwlr => self.dev.zwlr.setListener(*WaylandBackend, zwlr.dataControlDeviceListener, self),
    }
}

test "init and clean up" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var wayland_backend = try init(io, alloc);
    defer wayland_backend.deinit();
}
