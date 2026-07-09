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
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Type = std.builtin.Type;

const util = @import("util.zig");
const Validate = @import("Validate.zig");

/// I should add pretty error reporting and stuff like that.
/// Report to *Io.Writer, File. Maybe get some colour codes in there
/// if supported/desired. This should probably respect the common
/// envvars for disabling colouring.
///
/// Ensure you call `.deinit` once done with the data.
pub const Diagnostics = struct {
    message: []const u8 = "",

    /// Used when help is requested under a subcommand.
    command_path: []const u8 = "",

    pub fn deinit(diag: *Diagnostics, ctx: *ParseCtx) void {
        if (diag.message.len > 0)
            ctx.alloc.free(diag.message);
        if (diag.command_path.len > 0)
            ctx.alloc.free(diag.command_path);
    }

    // pub fn printHelp()? Maybe write some general write/print helpers.
};

pub const ArgsList = []const [:0]const u8;

pub const ParseError = error{
    UnknownFlag,
    UnknownCommand,
    InvalidValue,
    MissingValue,
    MissingPositional,
    MissingRequiredFlag,
    UnexpectedArgument,
    HelpRequested,
    /// Can be returned from custom parsers.
    /// Diagnostics should be set if present.
    Custom,
} || std.mem.Allocator.Error;

/// # Parse Context
///
/// Parsing context, used for basic types and can be used to implement
/// `parse(ctx: *ParseCtx) !T` for custom T.
///
/// # Notes
///
/// Note that parse is guaranteed not to be called if there are no
/// arguments left to parse.
pub const ParseCtx = struct {
    alloc: Allocator,
    /// Args can be consumed by the parser.
    args: ArgsList,
    idx: usize = 0,
    /// Optional runtime diagnostics.
    diag: ?*Diagnostics,
    /// Flag set once end of input reached. This means that if parser checks
    /// this flag it can return early.
    finished: bool = false,

    /// Returns null once the input is exhausted (and sets `finished`).
    /// Errors can be raised if more arguments were expected, for example.
    pub fn takeArg(self: *ParseCtx) ?[:0]const u8 {
        if (self.idx == self.args.len) {
            self.finished = true;
            return null;
        }

        const arg = self.args[self.idx];

        self.idx += 1;

        return arg;
    }

    /// Initialises a `ParseCtx`. Pass `diag` if you want error reporting.
    pub fn init(alloc: Allocator, args: ArgsList, diag: ?*Diagnostics) ParseCtx {
        return .{
            .alloc = alloc,
            .args = args,
            .diag = diag,
        };
    }
};

/// Call deinit on `ctx` when you are done.
pub fn parse(comptime T: type, ctx: *ParseCtx) ParseError!T {
    Validate.validate(T);

    return try parseInner(T, ctx, &.{});
}

/// Match `--name` (already stripped of dashes, before any '=') to a field index.
fn matchLong(comptime T: type, name: []const u8) ?usize {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |f, idx| {
        comptime if (util.isPositionalSlot(T, f.name)) continue;
        comptime if (util.subcommandField(T)) |u|
            if (std.mem.eql(u8, f.name, u.name)) continue;

        if (std.mem.eql(u8, name, comptime util.longName(f))) return idx;
    }
    return null;
}

/// Match a single short flag char to a field index.
/// Positionals and the subcommand union can never have shorts (validated).
fn matchShort(comptime T: type, c: u8) ?usize {
    const fields = @typeInfo(T).@"struct".fields;

    inline for (fields, 0..) |f, idx| {
        if (comptime util.shortFor(T, f.name)) |short| {
            if (c == short) return idx;
        }
    }

    return null;
}

/// Maps the positionals to field indices.
fn getPositionalIndices(comptime T: type) []const usize {
    comptime {
        const positionals = T.positionals;
        const positionals_info = @typeInfo(@TypeOf(positionals)).@"struct";
        var out: [positionals_info.fields.len]usize = undefined;

        for (positionals_info.fields, 0..) |pf, i| {
            const field = @field(positionals, pf.name);
            const field_name = @tagName(field);

            // Asserted already by validate.
            const idx = std.meta.fieldIndex(T, field_name).?;

            out[i] = idx;
        }

        const frozen = out;
        return &frozen;
    }
}

/// The accumulator type for a trailing variadic positional ([]const T tail),
/// or void when T has no such slot.
fn VariadicTail(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "positionals")) return void;

        const indices = getPositionalIndices(T);
        if (indices.len == 0) return void;

        const Last = @typeInfo(T).@"struct".fields[indices[indices.len - 1]].type;

        return switch (@typeInfo(Last)) {
            .pointer => |p| if (p.size == .slice and p.child != u8)
                std.ArrayListUnmanaged(p.child)
            else
                void,
            else => void,
        };
    }
}

/// True if the field at idx is a switch (takes no value).
fn isBoolField(comptime T: type, idx: usize) bool {
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        if (i == idx) {
            const F = switch (@typeInfo(f.type)) {
                .optional => |opt| opt.child,
                else => f.type,
            };

            return @typeInfo(F) == .bool;
        }
    }

    unreachable;
}

/// Records a diagnostic message and returns `err`.
fn fail(ctx: *ParseCtx, err: ParseError, comptime fmt: []const u8, args: anytype) ParseError {
    if (ctx.diag) |d| {
        if (d.message.len == 0)
            d.message = std.fmt.allocPrint(ctx.alloc, fmt, args) catch "";
    }

    return err;
}

/// Records which command level help was requested for, e.g. "peer add".
fn helpRequested(ctx: *ParseCtx, command_path: []const u8) ParseError {
    if (ctx.diag) |d|
        d.command_path = ctx.alloc.dupe(u8, command_path) catch "";

    return error.HelpRequested;
}

fn parseInner(comptime T: type, ctx: *ParseCtx, command_path: []const u8) ParseError!T {
    var result: T = undefined;
    const fields = @typeInfo(T).@"struct".fields;

    // Init any default fields.
    inline for (fields) |f| {
        @field(result, f.name) = f.defaultValue() orelse continue;
    }

    var seen_fields = std.StaticBitSet(fields.len).empty;

    // Whether a word (not flag) should be treated as positional, subcommand,
    // or error.
    const mode = comptime Validate.positionalOrSubcom(T);

    // Used for filling positional slots.
    var pos_idx: usize = 0;

    // Collects values for a trailing variadic positional, if T has one.
    var tail: VariadicTail(T) = if (comptime VariadicTail(T) != void) .empty else {};
    errdefer if (comptime VariadicTail(T) != void) tail.deinit(ctx.alloc);

    // Set if -- recieved. Essentially we just parse positionals.
    var end_of_flags = false;

    while (ctx.takeArg()) |arg| {
        if (!end_of_flags and std.mem.eql(u8, arg, "--")) {
            end_of_flags = true;
            continue;
        }

        // Long flag.
        if (!end_of_flags and std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const eq_value: ?[:0]const u8 = if (eq) |e| body[e + 1 ..] else null;

            if (std.mem.eql(u8, name, "help"))
                return helpRequested(ctx, command_path);

            const idx = matchLong(T, name) orelse
                return fail(ctx, error.UnknownFlag, "unknown flag --{s}", .{name});

            // The flag as the user spelled it, minus any =value part.
            const display = arg[0 .. name.len + 2];
            try assignField(T, &result, &seen_fields, idx, ctx, eq_value, display);

            continue;
        }

        // Short flag(s), possibly bundled (-vf): all but the last must be
        // switches since only the last can consume a value.
        if (!end_of_flags and arg.len > 1 and arg[0] == '-') {
            const body = arg[1..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const chars = if (eq) |e| body[0..e] else body;
            const eq_value: ?[:0]const u8 = if (eq) |e| body[e + 1 ..] else null;

            for (chars, 0..) |c, i| {
                const is_last = i == chars.len - 1;

                if (c == 'h')
                    return helpRequested(ctx, command_path);

                const idx = matchShort(T, c) orelse
                    return fail(ctx, error.UnknownFlag, "unknown flag -{c}", .{c});

                if (!is_last and !isBoolField(T, idx))
                    return fail(ctx, error.MissingValue, "flag -{c} takes a value so it must come last in \"{s}\"", .{ c, arg });

                const display = [_]u8{ '-', c };
                try assignField(T, &result, &seen_fields, idx, ctx, if (is_last) eq_value else null, &display);
            }

            continue;
        }

        // A bare word: a positional, a subcommand, or unexpected.
        if (comptime mode == .Positional) {
            const indices = comptime getPositionalIndices(T);

            if (comptime VariadicTail(T) != void) {
                // Everything from the tail slot onwards accumulates.
                if (pos_idx + 1 >= indices.len) {
                    const last_field = comptime fields[indices[indices.len - 1]];
                    const Elem = @typeInfo(last_field.type).pointer.child;

                    try tail.append(ctx.alloc, try parseValue(Elem, ctx, arg, comptime util.longName(last_field)));

                    pos_idx += 1;
                    continue;
                }
            }

            if (pos_idx >= indices.len)
                return fail(ctx, error.UnexpectedArgument, "unexpected argument \"{s}\"", .{arg});

            try assignField(T, &result, &seen_fields, indices[pos_idx], ctx, arg, null);
            pos_idx += 1;
        } else if (comptime mode == .Subcommand) {
            const subcommand_field = comptime util.subcommandField(T).?;

            // Asserted by validate.
            const Union = @typeInfo(subcommand_field.type).optional.child;

            // The child consumes every remaining arg, so the loop ends after this.
            @field(result, subcommand_field.name) = try parseSubcommand(Union, ctx, arg, command_path);
            seen_fields.set(comptime util.subcommandFieldIndex(T).?);
        } else {
            return fail(ctx, error.UnexpectedArgument, "unexpected argument \"{s}\"", .{arg});
        }
    }

    // Hand the accumulated variadic tail to its field.
    if (comptime VariadicTail(T) != void) {
        if (tail.items.len > 0) {
            const last_idx = comptime blk: {
                const indices = getPositionalIndices(T);
                break :blk indices[indices.len - 1];
            };

            @field(result, fields[last_idx].name) = try tail.toOwnedSlice(ctx.alloc);
            seen_fields.set(last_idx);
        }
    }

    // Anything required that was never given?
    inline for (fields, 0..) |f, i| {
        comptime if (util.subcommandField(T)) |u|
            if (std.mem.eql(u8, f.name, u.name)) continue;

        const required = comptime (f.defaultValue() == null and @typeInfo(f.type) != .optional);
        if (required and !seen_fields.isSet(i)) {
            if (comptime util.isPositionalSlot(T, f.name))
                return fail(ctx, error.MissingPositional, "missing required positional <{s}>", .{f.name});

            return fail(ctx, error.MissingRequiredFlag, "missing required flag --{s}", .{comptime util.longName(f)});
        }
    }

    return result;
}

/// Matches `word` against the union's tag names and parses the payload from
/// the remaining args. Owns (and frees) the command path it builds; help
/// requests dupe it into the Diagnostics first.
fn parseSubcommand(comptime U: type, ctx: *ParseCtx, word: []const u8, command_path: []const u8) ParseError!U {
    inline for (@typeInfo(U).@"union".fields) |uf| {
        if (std.mem.eql(u8, uf.name, word)) {
            const new_path = if (command_path.len > 0)
                try std.fmt.allocPrint(ctx.alloc, "{s} {s}", .{ command_path, uf.name })
            else
                try ctx.alloc.dupe(u8, uf.name);
            defer ctx.alloc.free(new_path);

            if (comptime uf.type == void) {
                // A payload-less command takes no further args, except help.
                if (ctx.takeArg()) |next| {
                    if (std.mem.eql(u8, next, "-h") or std.mem.eql(u8, next, "--help"))
                        return helpRequested(ctx, new_path);

                    return fail(ctx, error.UnexpectedArgument, "unexpected argument \"{s}\" after \"{s}\"", .{ next, new_path });
                }

                return @unionInit(U, uf.name, {});
            } else {
                return @unionInit(U, uf.name, try parseInner(uf.type, ctx, new_path));
            }
        }
    }

    return fail(ctx, error.UnknownCommand, "unknown command \"{s}\"", .{word});
}

/// Parses one value of type F. `value` is the inline `=value` part (or, for
/// positionals, the word itself); otherwise the next arg is consumed.
/// `display` is the user-facing spelling used in error messages.
fn parseValue(comptime F: type, ctx: *ParseCtx, value: ?[:0]const u8, display: []const u8) ParseError!F {
    switch (@typeInfo(F)) {
        .bool => {
            if (value != null)
                return fail(ctx, error.InvalidValue, "{s} is a switch and does not take a value", .{display});

            return true;
        },
        .optional => |opt| return try parseValue(opt.child, ctx, value, display),
        .int => {
            const s = value orelse ctx.takeArg() orelse
                return fail(ctx, error.MissingValue, "{s} expects a value", .{display});

            return std.fmt.parseInt(F, s, 0) catch
                return fail(ctx, error.InvalidValue, "invalid integer \"{s}\" for {s}", .{ s, display });
        },
        .@"enum" => {
            const s = value orelse ctx.takeArg() orelse
                return fail(ctx, error.MissingValue, "{s} expects a value", .{display});

            return std.meta.stringToEnum(F, s) orelse
                return fail(ctx, error.InvalidValue, "invalid value \"{s}\" for {s}", .{ s, display });
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return value orelse ctx.takeArg() orelse
                    return fail(ctx, error.MissingValue, "{s} expects a value", .{display});
            }

            // TODO: repeated list flags accumulate; needs shared state like
            // the variadic tail.
            return fail(ctx, error.InvalidValue, "list flags are not implemented yet ({s})", .{display});
        },
        .array => |arr| {
            const s = value orelse ctx.takeArg() orelse
                return fail(ctx, error.MissingValue, "{s} expects a value", .{display});

            if (s.len != arr.len)
                return fail(ctx, error.InvalidValue, "{s} expects exactly {d} bytes but got {d}", .{ display, arr.len, s.len });

            var out: F = if (comptime std.meta.sentinel(F) != null) @splat(0) else undefined;
            @memcpy(out[0..], s);

            return out;
        },
        // Validated to have a parse decl.
        .@"struct" => {
            if (value != null)
                return fail(ctx, error.InvalidValue, "{s} does not support =value syntax", .{display});

            // Custom parsers are guaranteed at least one remaining argument.
            if (ctx.idx >= ctx.args.len)
                return fail(ctx, error.MissingValue, "{s} expects a value", .{display});

            return F.parse(ctx) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                return fail(ctx, error.Custom, "invalid value for {s}", .{display});
            };
        },
        // Everything else was rejected by validation.
        else => comptime unreachable,
    }
}

/// The single place a field gets parsed, stored, and marked seen.
/// Passing null for `display` uses the field's long name in messages.
fn assignField(
    comptime T: type,
    result: *T,
    seen: *std.StaticBitSet(@typeInfo(T).@"struct".fields.len),
    idx: usize,
    ctx: *ParseCtx,
    eq_value: ?[:0]const u8,
    display: ?[]const u8,
) ParseError!void {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |f, i| {
        // The subcommand union is never assigned here, and its type would
        // not instantiate under parseValue.
        comptime if (util.subcommandField(T)) |u|
            if (std.mem.eql(u8, f.name, u.name)) continue;

        if (i == idx) {
            const disp = display orelse comptime util.longName(f);

            @field(result, f.name) = try parseValue(f.type, ctx, eq_value, disp);
            seen.set(i);

            return;
        }
    }

    // idx came from a matcher so this should never be hit.
    unreachable;
}

test "comptime lookup helpers" {
    const T = struct {
        config_path: ?[]const u8 = null,
        verbose: bool = false,
        name: []const u8 = "",

        command: ?union(enum) {
            run: struct {},
            version: void,
        } = null,

        pub const flags = .{
            .config_path = .{ .short = 'c' },
        };
    };

    const P = struct {
        name: []const u8,
        force: bool = false,

        pub const positionals = .{.name};
    };

    const fields = @typeInfo(T).@"struct".fields;

    try std.testing.expectEqualStrings("config-path", comptime util.longName(fields[0]));
    try std.testing.expectEqualStrings("verbose", comptime util.longName(fields[1]));

    try std.testing.expectEqual(@as(?u8, 'c'), comptime util.shortFor(T, "config_path"));
    try std.testing.expectEqual(@as(?u8, null), comptime util.shortFor(T, "verbose"));
    try std.testing.expectEqual(@as(?u8, null), comptime util.shortFor(P, "name"));

    try std.testing.expect(comptime util.isPositionalSlot(P, "name"));
    try std.testing.expect(comptime !util.isPositionalSlot(P, "force"));
    try std.testing.expect(comptime !util.isPositionalSlot(T, "name"));

    try std.testing.expectEqualStrings("command", comptime (util.subcommandField(T) orelse unreachable).name);
    try std.testing.expect(comptime util.subcommandField(P) == null);
}

test "parseInner: long, short and bundled flags" {
    const T = struct {
        verbose: bool = false,
        force: bool = false,
        config_path: ?[]const u8 = null,
        retries: u32 = 3,
        colour: enum { auto, always, never } = .auto,

        pub const flags = .{
            .verbose = .{ .short = 'v' },
            .force = .{ .short = 'f' },
            .config_path = .{ .short = 'c' },
        };
    };

    var ctx = ParseCtx.init(std.testing.allocator, &.{
        "--config-path=/tmp/conf", "-vf", "--retries", "7", "--colour=always",
    }, null);

    const r = try parseInner(T, &ctx, "");

    try std.testing.expect(r.verbose);
    try std.testing.expect(r.force);
    try std.testing.expectEqualStrings("/tmp/conf", r.config_path.?);
    try std.testing.expectEqual(@as(u32, 7), r.retries);
    try std.testing.expect(r.colour == .always);
}

test "parseInner: short flag with separate and =value" {
    const T = struct {
        config_path: ?[]const u8 = null,
        verbose: bool = false,

        pub const flags = .{
            .config_path = .{ .short = 'c' },
            .verbose = .{ .short = 'v' },
        };
    };

    var ctx = ParseCtx.init(std.testing.allocator, &.{ "-c", "/a" }, null);
    const r = try parseInner(T, &ctx, "");
    try std.testing.expectEqualStrings("/a", r.config_path.?);

    var ctx2 = ParseCtx.init(std.testing.allocator, &.{"-vc=/b"}, null);
    const r2 = try parseInner(T, &ctx2, "");
    try std.testing.expect(r2.verbose);
    try std.testing.expectEqualStrings("/b", r2.config_path.?);
}

test "parseInner: positionals fill in order, flags interleaved" {
    const T = struct {
        name: []const u8,
        pubkey: []const u8,
        force: bool = false,

        pub const positionals = .{ .name, .pubkey };
    };

    var ctx = ParseCtx.init(std.testing.allocator, &.{ "Jane", "--force", "pubkey123" }, null);
    const r = try parseInner(T, &ctx, "");

    try std.testing.expectEqualStrings("Jane", r.name);
    try std.testing.expectEqualStrings("pubkey123", r.pubkey);
    try std.testing.expect(r.force);
}

test "parseInner: variadic tail collects the rest" {
    const T = struct {
        first: []const u8,
        rest: []const []const u8 = &.{},

        pub const positionals = .{ .first, .rest };
    };

    var ctx = ParseCtx.init(std.testing.allocator, &.{ "a", "b", "c" }, null);
    const r = try parseInner(T, &ctx, "");
    defer std.testing.allocator.free(r.rest);

    try std.testing.expectEqualStrings("a", r.first);
    try std.testing.expectEqual(@as(usize, 2), r.rest.len);
    try std.testing.expectEqualStrings("b", r.rest[0]);
    try std.testing.expectEqualStrings("c", r.rest[1]);
}

test "parseInner: -- ends flag parsing" {
    const T = struct {
        word: []const u8,

        pub const positionals = .{.word};
    };

    var ctx = ParseCtx.init(std.testing.allocator, &.{ "--", "--not-a-flag" }, null);
    const r = try parseInner(T, &ctx, "");

    try std.testing.expectEqualStrings("--not-a-flag", r.word);
}

test "parseInner: diagnostics on errors" {
    const T = struct {
        name: []const u8,
        retries: u32 = 3,

        pub const positionals = .{.name};
    };

    {
        var diag: Diagnostics = .{};
        var ctx = ParseCtx.init(std.testing.allocator, &.{"--wat"}, &diag);
        defer diag.deinit(&ctx);

        try std.testing.expectError(error.UnknownFlag, parseInner(T, &ctx, ""));
        try std.testing.expectEqualStrings("unknown flag --wat", diag.message);
    }

    {
        var diag: Diagnostics = .{};
        var ctx = ParseCtx.init(std.testing.allocator, &.{}, &diag);
        defer diag.deinit(&ctx);

        try std.testing.expectError(error.MissingPositional, parseInner(T, &ctx, ""));
        try std.testing.expectEqualStrings("missing required positional <name>", diag.message);
    }

    {
        var diag: Diagnostics = .{};
        var ctx = ParseCtx.init(std.testing.allocator, &.{ "Jane", "--retries", "lots" }, &diag);
        defer diag.deinit(&ctx);

        try std.testing.expectError(error.InvalidValue, parseInner(T, &ctx, ""));
        try std.testing.expectEqualStrings("invalid integer \"lots\" for --retries", diag.message);
    }
}

test "parseInner: subcommands route and recurse" {
    const PeerAdd = struct {
        name: []const u8,
        pubkey: []const u8,
        force: bool = false,

        pub const positionals = .{ .name, .pubkey };
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
        } = null,
    };

    var ctx = ParseCtx.init(std.testing.allocator, &.{
        "--verbose", "peer", "add", "Jane", "pubkey123", "--force",
    }, null);

    const r = try parseInner(Root, &ctx, "");

    try std.testing.expect(r.verbose);

    const add = r.command.?.peer.action.?.add;
    try std.testing.expectEqualStrings("Jane", add.name);
    try std.testing.expectEqualStrings("pubkey123", add.pubkey);
    try std.testing.expect(add.force);
}

test "parseInner: void subcommand takes no args" {
    const Root = struct {
        command: ?union(enum) {
            run: struct { fast: bool = false },
            version: void,
        } = null,
    };

    var ctx = ParseCtx.init(std.testing.allocator, &.{"version"}, null);
    const r = try parseInner(Root, &ctx, "");
    try std.testing.expect(r.command.? == .version);

    var diag: Diagnostics = .{};
    var ctx2 = ParseCtx.init(std.testing.allocator, &.{ "version", "extra" }, &diag);
    defer diag.deinit(&ctx2);

    try std.testing.expectError(error.UnexpectedArgument, parseInner(Root, &ctx2, ""));
    try std.testing.expectEqualStrings("unexpected argument \"extra\" after \"version\"", diag.message);
}

test "parseInner: unknown command" {
    const Root = struct {
        command: ?union(enum) {
            run: struct {},
        } = null,
    };

    var diag: Diagnostics = .{};
    var ctx = ParseCtx.init(std.testing.allocator, &.{"walk"}, &diag);
    defer diag.deinit(&ctx);

    try std.testing.expectError(error.UnknownCommand, parseInner(Root, &ctx, ""));
    try std.testing.expectEqualStrings("unknown command \"walk\"", diag.message);
}

test "parseInner: help deep in the tree records the full path" {
    const PeerOpts = struct {
        action: ?union(enum) {
            add: struct { name: ?[]const u8 = null },
        } = null,
    };

    const Root = struct {
        command: ?union(enum) {
            peer: PeerOpts,
        } = null,
    };

    var diag: Diagnostics = .{};
    var ctx = ParseCtx.init(std.testing.allocator, &.{ "peer", "add", "-h" }, &diag);
    defer diag.deinit(&ctx);

    try std.testing.expectError(error.HelpRequested, parseInner(Root, &ctx, ""));
    try std.testing.expectEqualStrings("peer add", diag.command_path);
}

test "parseInner: help records the command path" {
    const T = struct {
        verbose: bool = false,
    };

    var diag: Diagnostics = .{};
    var ctx = ParseCtx.init(std.testing.allocator, &.{"-h"}, &diag);
    defer diag.deinit(&ctx);

    try std.testing.expectError(error.HelpRequested, parseInner(T, &ctx, "peer add"));
    try std.testing.expectEqualStrings("peer add", diag.command_path);
}
