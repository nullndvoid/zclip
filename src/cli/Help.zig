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

    try writer.print("POSITIONAL ARGS\n\n", .{});

    inline for (pos[0 .. pos.len - 1]) |p| {
        try writer.print("{s} ", .{p.name});
    }

    try writer.writeAll(pos[pos.len - 1].name);
    try writer.writeAll("\n");

    try writer.flush();
}

/// One entry of the comptime command-path mapping: the path as recorded by
/// the parser in `Diagnostics.command_path` (e.g. "peer add") and the opts
/// struct parsed under that command.
const PathEntry = struct {
    path: []const u8,
    T: type,
};

/// Stand-in payload for void subcommands, which have no flags of their own.
const NoOpts = struct {};

/// Builds the full "command path" -> type mapping for T's subcommand tree.
/// "" maps to T itself, "peer" to the peer payload, "peer add" to its child,
/// and so on.
fn pathEntries(comptime T: type) []const PathEntry {
    comptime {
        const root: []const PathEntry = &.{.{ .path = "", .T = T }};
        return root ++ subEntries(T, "");
    }
}

fn subEntries(comptime T: type, comptime prefix: []const u8) []const PathEntry {
    comptime {
        var entries: []const PathEntry = &.{};

        const sub = util.subcommandField(T) orelse return entries;
        const Union = @typeInfo(sub.type).optional.child;

        for (@typeInfo(Union).@"union".fields) |uf| {
            const path = if (prefix.len > 0) prefix ++ " " ++ uf.name else uf.name;

            if (uf.type == void) {
                entries = entries ++ .{PathEntry{ .path = path, .T = NoOpts }};
            } else {
                entries = entries ++ .{PathEntry{ .path = path, .T = uf.type }};
                entries = entries ++ subEntries(uf.type, path);
            }
        }

        return entries;
    }
}

/// Writes help for the command level the user asked about, selecting the
/// type via `Diagnostics.command_path` ("" selects T, "peer add" selects the
/// nested payload). Unknown paths fall back to root help.
pub fn writeHelpForPath(
    comptime T: type,
    comptime opts: Opts,
    command_path: []const u8,
    writer: *Io.Writer,
) !void {
    const entries = comptime pathEntries(T);

    inline for (entries) |entry| {
        if (std.mem.eql(u8, command_path, entry.path)) {
            const entry_opts = comptime if (entry.path.len == 0) opts else Opts{
                .program_name = if (opts.program_name) |name|
                    name ++ " " ++ entry.path
                else
                    entry.path,
                .show_usage = opts.show_usage,
                .show_defaults = opts.show_defaults,
            };

            return writeHelp(entry.T, entry_opts, writer);
        }
    }

    return writeHelp(T, opts, writer);
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

        const sub = util.subcommandField(T) orelse return subcoms;
        const Union = @typeInfo(sub.type).optional.child;

        // Descriptions come from a `help` decl on the union itself, keyed by
        // subcommand name. Void subcommands cannot carry decls of their own.
        for (@typeInfo(Union).@"union".fields) |uf| {
            subcoms = subcoms ++ .{Subcommand{
                .name = uf.name,
                .description = util.descriptionOf(Union, uf.name),
            }};
        }

        return subcoms;
    }
}

test "writeHelpForPath selects the level named by the command path" {
    const PeerAdd = struct {
        name: []const u8,
        pubkey: []const u8,
        force: bool = false,

        pub const positionals = .{ .name, .pubkey };

        pub const help = .{
            .force = .{ .desc = "Overwrite an existing peer" },
        };
    };

    const PeerOpts = struct {
        action: ?union(enum) {
            add: PeerAdd,
            list: void,
        } = null,
    };

    const Root = struct {
        verbose: bool = false,

        command: ?union(enum) {
            peer: PeerOpts,
            version: void,

            pub const help = .{
                .peer = .{ .desc = "Manage peers" },
                .version = .{ .desc = "Print the version" },
            };
        } = null,
    };

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    // "" -> Root: shows root subcommands with their descriptions, not peer's flags.
    try writeHelpForPath(Root, .{ .program_name = "tool" }, "", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "peer") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Manage peers") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Print the version") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "--force") == null);

    // "peer" -> PeerOpts: its action union has no help decl, so bare names.
    aw.clearRetainingCapacity();
    try writeHelpForPath(Root, .{ .program_name = "tool" }, "peer", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Manage peers") == null);

    // "peer add" -> PeerAdd: shows its flags and positionals.
    aw.clearRetainingCapacity();
    try writeHelpForPath(Root, .{ .program_name = "tool" }, "peer add", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "tool peer add") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "--force") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "pubkey") != null);

    // "version" -> void payload: only the built-in help flag.
    aw.clearRetainingCapacity();
    try writeHelpForPath(Root, .{ .program_name = "tool" }, "version", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "--help") != null);

    // Unknown paths fall back to root help.
    aw.clearRetainingCapacity();
    try writeHelpForPath(Root, .{ .program_name = "tool" }, "bogus", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "peer") != null);
}

fn positionals(comptime T: type, comptime _: Opts) []const Positional {
    comptime {
        var subcoms: []const Positional = &.{};

        for (@typeInfo(T).@"struct".fields) |f| {
            if (util.isPositionalSlot(T, f.name)) {
                subcoms = subcoms ++ .{Positional{
                    .name = util.longName(f),
                }};
            }
        }

        return subcoms;
    }
}
