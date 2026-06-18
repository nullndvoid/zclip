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

const zclip = @import("zclip");
const Clip = zclip.Clip;
const Clipboard = zclip.Clipboard;
const Command = Clipboard.Command;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var clipboard = try Clipboard.init(io, &arena, .{});
    defer clipboard.deinit();

    const stdin = Io.File.stdin();
    defer stdin.close(io);

    var stdin_buf: [512]u8 = undefined;
    var stdin_file_rdr = stdin.reader(io, &stdin_buf);
    const rdr = &stdin_file_rdr.interface;
    var line: ?[]u8 = try rdr.takeDelimiter('\n');

    while (line != null) {
        const cmd = parseCommand(line.?);

        std.log.debug("Got command: {t}", .{cmd});

        try clipboard.sendCommandRaw(cmd);

        if (cmd == .Stop) {
            break;
        }

        line = try rdr.takeDelimiter('\n');
    }
}

fn parseCommand(input: []const u8) Command {
    const line = std.mem.trim(u8, input, " \t\r");

    if (std.mem.eql(u8, line, "stop")) {
        return .Stop;
    }

    return .{ .Clip = .{
        .data = line,
        .is_text = true,
        .mime_type = "text/plain;charset=utf-8",
    } };
}
