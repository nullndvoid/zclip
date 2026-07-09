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

const util = @import("util.zig");

pub const Opts = struct {
    program_name: ?[]const u8 = null,
    program_desc: ?[]const u8 = null,
    show_usage: bool = false,
    show_defaults: bool = false,
};

/// T should have already been validated against the schema.
pub fn writeHelp(comptime T: type, comptime opts: Opts, writer: *Io.Writer) !void {
    const cli_flags = comptime flags(T, opts);
    const subcoms = comptime subcommands(T, opts);
    const pos = comptime positionals(T, opts);

    if (opts.program_name) |name| {
        try writer.writeAll(name ++ "\n\n");
    }

    if (opts.program_desc) |desc| {
        try writer.writeAll(desc ++ "\n\n");
    }

    try writer.print("FLAGS\n\n", .{});
    try writer.print("--help, -h\t\tDisplay this help menu\n", .{});

    inline for (cli_flags) |flag| {
        try writer.print("--{s}", .{flag.long_name});
        if (flag.short_name) |short|
            try writer.print(", -{c}", .{short});
        if (flag.description) |desc|
            try writer.print("\t\t{s}", .{desc});

        try writer.print("\n", .{});
    }

    try writer.writeAll("\n");
    try writer.flush();

    if (subcoms.len > 0)
        try writer.print("SUBCOMMANDS\n\n", .{});

    inline for (subcoms) |subcom| {
        try writer.print("{s}", .{subcom.name});

        if (subcom.description) |desc|
            try writer.print("\t\t{s}", .{desc});

        try writer.writeAll("\n");
    }

    try writer.flush();

    if (pos.len == 0)
        return;

    try writer.print("POSITIONAL ARGS", .{});

    inline for (pos[0 .. pos.len - 1]) |p| {
        try writer.print("{s} ", p.name);
    }

    try writer.writeAll(pos[pos.len - 1].name);

    try writer.flush();
}

const FlagTriple = struct {
    long_name: []const u8,
    short_name: ?u8,
    description: ?[]const u8,
};

const Subcommand = struct {
    name: []const u8,
    description: ?[]const u8,
};

const Positional = struct { name: []const u8 };

/// Collects a list of { long_name, ?short_name, ?desc } to be displayed.
fn flags(comptime T: type, comptime _: Opts) []const FlagTriple {
    comptime {
        var triples: []const FlagTriple = &.{};

        for (@typeInfo(T).@"struct".fields) |f| {
            if (util.isPositionalSlot(T, f.name)) continue;
            if (util.isSubcommand(T, f.name)) continue;

            triples = triples ++ .{FlagTriple{
                .long_name = util.longName(f),
                .short_name = util.shortFor(T, f.name),
                .description = util.descriptionOf(T, f.name),
            }};
        }

        return triples;
    }
}

fn subcommands(comptime T: type, comptime _: Opts) []const Subcommand {
    comptime {
        var subcoms: []const Subcommand = &.{};

        for (@typeInfo(T).@"struct".fields) |f| {
            if (util.isSubcommand(T, f.name)) {
                // Iterate over field names.
                for (@typeInfo(@typeInfo(util.subcommandField(T).?.type).optional.child).@"union".fields) |uf| {
                    subcoms = subcoms ++ .{Subcommand{
                        .name = uf.name,
                        .description = null, // TODO:
                    }};
                }
            }
        }

        return subcoms;
    }
}

fn positionals(comptime T: type, comptime _: Opts) []const Positional {
    comptime {
        var subcoms: []const Positional = &.{};

        for (@typeInfo(T).@"struct".fields) |f| {
            if (util.isPositionalSlot(T, f.name)) {
                subcoms = subcoms ++ .{Positional{
                    .name = util.longName(f),
                    .description = util.descriptionOf(T, f.name),
                }};
            }
        }

        return subcoms;
    }
}
