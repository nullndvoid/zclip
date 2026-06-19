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

//! Will be both the client and daemon implementations.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const build_options = @import("options");
const clap = @import("clap");
const zclip = @import("zclip");
const Clip = zclip.Clip;
const Clipboard = zclip.Clipboard;
const Command = Clipboard.Command;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    setupAndParseArgs(io, alloc, init.minimal.args) catch |err| switch (err) {
        error.ShouldExit => return,
        else => return err,
    };

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

fn setupAndParseArgs(io: Io, alloc: Allocator, args: std.process.Args) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_file = Io.File.stderr();
    defer stderr_file.close(io);

    var file_writer = stderr_file.writer(io, &stderr_buf);
    var writer = &file_writer.interface;

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(
        clap.Help,
        &params,
        clap.parsers.default,
        args,
        .{
            .diagnostic = &diag,
            .allocator = alloc,
        },
    ) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writer.print(preamble, .{});
        try writer.flush();

        try clap.helpToFile(io, .stderr(), clap.Help, &params, .{});
        try writer.print(postscript, .{});
        try writer.flush();

        return error.ShouldExit;
    } else if (res.args.version != 0) {
        if (build_options.git_rev) |rev| {
            try writer.print(
                "zclip {s} ({s})\n",
                .{ build_options.version, rev },
            );
        } else {
            try writer.print(
                "zclip {s}\n",
                .{build_options.version},
            );
        }

        try writer.flush();

        return error.ShouldExit;
    }
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

const preamble =
    \\ zclip
    \\
    \\ A program to manage your clipboard, including over a network.
    \\
    \\
;
const postscript =
    \\
    \\ This program is distributed in the hope that it will be useful,
    \\ but WITHOUT ANY WARRANTY; without even the implied warranty of
    \\ MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    \\ GNU General Public License for more details.
    \\
;

const params = clap.parseParamsComptime(
    \\-h, --help            Display this help and exit
    \\--version             Show the version of the software
    \\-v, --verbose         Set the default log level to debug
);
