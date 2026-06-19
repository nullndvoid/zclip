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

const build_options = @import("options");
const clap = @import("clap");
const zclip = @import("zclip");
const Clip = zclip.Clip;
const Clipboard = zclip.Clipboard;
const Command = Clipboard.Command;

const Cli = @import("Cli.zig");

const log = std.log.scoped(.zclip);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    var cli_args = Cli.CliOpts{};

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    Cli.setupAndParseArgs(io, &arena, init.minimal.args, &cli_args) catch {
        std.process.exit(1);
    };

    if (cli_args.should_exit) return;
}

fn parseCommand(input: []const u8) Command {
    const line = std.mem.trim(u8, input, " \t\r");

    if (std.mem.eql(u8, line, "stop")) {
        return .Stop;
    }

    return .{ .WriteClipboard = .{
        .data = line,
        .is_text = true,
        .mime_type = "text/plain;charset=utf-8",
    } };
}
