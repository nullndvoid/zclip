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

//! Windows support.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Io = std.Io;
const Future = Io.Future;

const win32 = @import("win32").everything;
const HWND = win32.HWND;
const WNDCLASSEXW = win32.WNDCLASSEXW;
const LRESULT = win32.LRESULT;
const LPARAM = win32.LPARAM;
const WPARAM = win32.WPARAM;
const WM_CLIPBOARDUPDATE = win32.WM_CLIPBOARDUPDATE;
const WM_DESTROY = win32.WM_DESTROY;

const zclip = @import("root.zig");
const ClipQueue = zclip.ClipQueue;
const Clip = zclip.Clip;

const log = std.log.scoped(.Windows);

hwnd: HWND,
io: Io,
arena: *Arena,
/// Allocates the clip payloads handed over via `clip_queue`; the queue
/// consumer owns and frees them.
clip_alloc: Allocator,
worker_handle: Future(anyerror!void),
lang_id: u32,
clip_queue: *ClipQueue,

const Windows = @This();

/// Used by windowProc because Microslop loves globals.
var lang_id_global: u32 = undefined;
var alloc_global: Allocator = undefined;

pub fn init(io: Io, arena: *Arena, clip_alloc: Allocator, clip_queue: *ClipQueue) !*Windows {
    var hwnd: HWND = undefined;
    const lang_id = win32.GetUserDefaultUILanguage();

    const hinst = win32.GetModuleHandleW(null);
    if (hinst == null) {
        printErrorWithLangId(arena.allocator(), lang_id, "GetModuleHandleW");

        return error.WindowInit;
    }

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zclip_clip_listener");
    const window_name = std.unicode.utf8ToUtf16LeStringLiteral("zclip");

    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = hinst;
    wc.lpszClassName = class_name;

    const atom = win32.RegisterClassExW(&wc);
    if (atom == 0) {
        printErrorWithLangId(arena.allocator(), lang_id, "RegisterClassExW");

        return error.WindowInit;
    }

    hwnd = win32.CreateWindowExW(
        std.mem.zeroes(win32.WINDOW_EX_STYLE),
        class_name,
        window_name,
        std.mem.zeroes(win32.WINDOW_STYLE),
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        hinst,
        null,
    ) orelse {
        printErrorWithLangId(arena.allocator(), lang_id, "CreateWindowExW");

        return error.WindowInit;
    };

    if (win32.AddClipboardFormatListener(hwnd) == 0) {
        printErrorWithLangId(arena.allocator(), lang_id, "AddClipboardFormatListener");

        return error.ListenerFailed;
    }

    const self = try arena.allocator().create(Windows);

    self.* = .{
        .io = io,
        .hwnd = hwnd,
        .arena = arena,
        .clip_alloc = clip_alloc,
        .worker_handle = try io.concurrent(workerThread, .{
            self,
        }),
        .lang_id = lang_id,
        .clip_queue = clip_queue,
    };

    lang_id_global = lang_id;
    alloc_global = arena.allocator();

    return self;
}

pub fn deinit(self: *Windows) void {
    _ = win32.RemoveClipboardFormatListener(self.hwnd);
    _ = win32.DestroyWindow(self.hwnd);
}

pub fn setClipboard(_: *Windows, _: Clip) !void {
    @panic("TODO");
}

fn printErrorWithLangId(allocator: Allocator, lang_id: u32, fn_name: []const u8) void {
    const err = win32.GetLastError();
    if (err == .NO_ERROR) return;

    const buf: [*:0]u16 = undefined;

    const fmt_res = win32.FormatMessageW(
        win32.FORMAT_MESSAGE_OPTIONS{ .ALLOCATE_BUFFER = 1, .FROM_SYSTEM = 1, .IGNORE_INSERTS = 1 },
        null,
        @intFromEnum(err),
        lang_id,
        buf,
        0,
        null,
    );

    if (fmt_res == 0) {
        log.err("{s} failed with error {t}", .{ fn_name, err });
        log.err("FormatMessageW failed with error {t}", .{win32.GetLastError()});
        return;
    }

    defer _ = win32.LocalFree(@intCast(@intFromPtr(buf)));

    const wtf8_str = std.unicode.wtf16LeToWtf8Alloc(allocator, buf[0..fmt_res]) catch return;
    const utf8_str = std.unicode.wtf8ToUtf8LossyAlloc(allocator, wtf8_str) catch return;
    defer allocator.free(wtf8_str);
    defer allocator.free(utf8_str);

    log.err("{s} failed with error {t}: {s}", .{ fn_name, err, utf8_str });
}

fn printError(self: *const Windows, fn_name: []const u8) void {
    printErrorWithLangId(self.arena.allocator(), self.lang_id, fn_name);
}

/// An event loop to get and send messages.
fn workerThread(self: *Windows) anyerror!void {
    var ret: win32.BOOL = 1;
    var msg: win32.MSG = undefined;

    while (ret != 0) {
        ret = win32.GetMessageW(&msg, null, 0, 0);
        if (ret == -1) {
            self.printError("GetMessageW");

            // For now just continue once the error is logged. TODO: Figure out what is fatal.
            continue;
        }

        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

fn windowProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CLIPBOARDUPDATE => {
            if (win32.OpenClipboard(hwnd) == 0) {
                printErrorWithLangId(alloc_global, lang_id_global, "OpenClipboard");
                log.err("Failed to open clipboard. Some data may be lost.", .{});
                return 0;
            }

            defer {
                const err = win32.CloseClipboard();
                if (err == 0) {
                    const last_err = win32.GetLastError();
                    printErrorWithLangId(alloc_global, lang_id_global, "CloseClipboard");

                    if (last_err == .NO_ERROR) {} else {
                        log.err("Failed to close clipboard.", .{});
                    }
                }
            }

            var fmt: u32 = 0;
            var fallback_text: bool = false;

            while (true) {
                fmt = win32.EnumClipboardFormats(fmt);
                // Handle both end of list and error cases.
                if (fmt == 0) {
                    const err = win32.GetLastError();

                    printErrorWithLangId(alloc_global, lang_id_global, "EnumClipboardFormats");

                    if (err != .NO_ERROR) {
                        log.err("EnumClipboardFormats failed. Got {t}. Falling back to text.", .{err});
                        fallback_text = true;
                    }

                    break;
                }

                // For now just log the formats.
                log.debug("Got clipboard format {d}", .{fmt});
            }

            if (fallback_text) {
                // TODO: Get just text.
                return 0;
            }

            // TODO: Happy path.

            return 0;
        },
        WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
