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
const Type = std.builtin.Type;
const comptimePrint = std.fmt.comptimePrint;

/// Returns the not fully qualified name of a type.
fn typeName(comptime T: type) [:0]const u8 {
    const type_name = @typeName(T);
    const idx = std.mem.lastIndexOfScalar(u8, type_name, '.') orelse return type_name;
    return type_name[idx + 1 ..];
}

fn fieldNameStr(comptime T: type, comptime field_or_index: union(enum) { f: [:0]const u8, i: usize }) [:0]const u8 {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {},
        else => complain("This is a bug. fieldNameStr called on invalid type!", .{}),
    }

    return switch (field_or_index) {
        .f => |n| typeName(T) ++ "." ++ n,
        .i => |i| comptimePrint("{s} field {d}", .{ typeName(T), i }),
    };
}

fn complain(comptime fmt: [:0]const u8, comptime args: anytype) noreturn {
    @compileError(comptimePrint(fmt, args));
}

/// True for string-ish types: u8 slices and pointers to u8 arrays (string literals).
fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |arr| {
            if (arr.child != u8) return false;
            if (arr.sentinel()) |s| return s == 0;
            return true;
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => isString(ptr.child),
            else => false,
        },
        else => false,
    };
}

/// The layout of the help struct value to be validated.
///
/// ```zig
/// pub const help = .{
///     // This may be omitted.
///     .usage = "usage: ...",
///     .field_name = .{
///         .desc = "what this option does",
///         // This may be omitted. Used for displaying the default value.
///         // For custom types, define `pub fn defaultDisplay(w: *Io.Writer) !void`.
///         .default = some_value,
///     },
/// };
/// ```
fn validateHelp(comptime T: type, comptime fields: []const Type.StructField) void {
    const help = T.help;
    const Help = @TypeOf(help);

    if (@hasField(Help, "help") or @hasField(Help, "h")) {
        complain("{s}.help contains field for reserved help flag!", .{typeName(T)});
    }

    if (@typeInfo(Help) != .@"struct")
        complain("{s}.help must be a struct value, e.g. `pub const help = .{{ ... }};`", .{typeName(T)});

    inline for (@typeInfo(Help).@"struct".fields) |hf| {
        if (std.mem.eql(u8, hf.name, "usage")) {
            if (!isString(@TypeOf(help.usage)))
                complain("{s}.help.usage should be a string. Omit if not needed!", .{typeName(T)});
            continue;
        }

        const original_field_idx = std.meta.fieldIndex(T, hf.name) orelse
            complain("{s}.help got invalid field name: {s}", .{ typeName(T), hf.name });

        validateHelpForField(T, fields[original_field_idx], @field(help, hf.name));
    }
}

fn validateHelpForField(comptime T: type, comptime original: Type.StructField, comptime entry: anytype) void {
    const Entry = @TypeOf(entry);

    if (@typeInfo(Entry) != .@"struct")
        complain("{s}.help.{s} should be a struct: .{{ .desc = \"...\", .default = ... }}", .{ typeName(T), original.name });

    // This should have required desc, optional default.
    if (!@hasField(Entry, "desc"))
        complain("{s}.{s} help missing a `desc: []const u8` field!", .{ typeName(T), original.name });

    if (!isString(@TypeOf(entry.desc)))
        complain("{s}.{s} help description should be a string!", .{ typeName(T), original.name });

    const has_default = @hasField(Entry, "default");

    if (has_default and isSubcommandUnion(original.type))
        complain("{s}.{s} help, default not allowed on subcommand unions!", .{ typeName(T), original.name });

    // Catch typos like `dsec` or `defualt` without looping: only desc and default are known.
    const known_fields = 1 + @as(usize, @intFromBool(has_default));
    if (@typeInfo(Entry).@"struct".fields.len > known_fields)
        complain("{s}.{s} help has unknown fields. Only `desc` and `default` are recognized.", .{ typeName(T), original.name });

    if (!has_default) return;

    const EntryDefaultT = @TypeOf(entry.default);
    const FieldT = original.type;

    switch (@typeInfo(EntryDefaultT)) {
        .enum_literal => {
            const Target = switch (@typeInfo(FieldT)) {
                .optional => |opt| opt.child,
                else => FieldT,
            };

            if (@typeInfo(Target) != .@"enum")
                complain("{s}.{s} help default is an enum literal, but the field type is {s}!", .{ typeName(T), original.name, typeName(FieldT) });

            if (!@hasField(Target, @tagName(entry.default)))
                complain("{s}.{s} help default `.{s}` is not a member of {s}!", .{ typeName(T), original.name, @tagName(entry.default), typeName(Target) });

            return;
        },
        // Untyped literals: coercion failure here means the default doesn't fit the field type.
        .comptime_int, .comptime_float, .null => {
            const coerced: FieldT = entry.default;
            _ = coerced;
            return;
        },
        else => {},
    }

    // String literals are pointers to arrays, never exactly []const u8.
    if (isString(EntryDefaultT)) {
        const coerced: FieldT = entry.default;
        _ = coerced;
        return;
    }

    if (EntryDefaultT != FieldT)
        complain(
            "{s}.{s} help default is the wrong type! Expected `{s}` but got `{s}`.",
            .{ typeName(T), original.name, typeName(original.type), typeName(EntryDefaultT) },
        );
}

pub fn validate(comptime T: type) void {
    comptime validateStruct(T);
}

pub const ParseMode = enum {
    Positional,
    Subcommand,
    Neither,
};

pub fn positionalOrSubcom(comptime T: type) ParseMode {
    if (@hasDecl(T, "positionals")) return .Positional;

    var got_union: bool = false;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        comptime if (!isSubcommandUnion(f.type)) continue;
        got_union = true;
    }

    return if (got_union) .Subcommand else .Neither;
}

/// I want to scan struct fields and check their types are valid as first pass.
/// Then I will worry about the rest later. This will compile error for invalid inputs.
/// Allows tuples in order to handle a list of args with various types.
fn validateStruct(comptime T: type) void {
    var got_union = false;

    if (@hasField(T, "help") or @hasField(T, "h")) {
        complain("{s} contains field for reserved help flag!", .{typeName(T)});
    }

    switch (@typeInfo(T)) {
        .@"struct" => |data| {
            inline for (data.fields, 0..) |field, i| {
                const field_name =
                    if (!data.is_tuple)
                        fieldNameStr(T, .{ .f = field.name })
                    else
                        fieldNameStr(T, .{ .i = i });

                if (std.mem.containsAtLeast(u8, field.name, 1, "="))
                    complain("Field names ({s}) must not contain '='!", .{field_name});

                if (!data.is_tuple and std.mem.containsAtLeast(u8, field.name, 1, " "))
                    complain("Field names ({s}) must not contain spaces!", .{field_name});

                // We should see an error if there was a duplicate union, so we
                // can take this to be the only one (if present).
                validateField(field.type, field_name, &got_union);
            }

            if (@hasDecl(T, "help"))
                validateHelp(T, data.fields);

            if (@hasDecl(T, "positionals"))
                validatePositionals(T);

            if (@hasDecl(T, "flags"))
                validateFlags(T, data.fields);

            // Don't bother scanning if not found.
            if (!got_union) return;

            if (@hasDecl(T, "positionals"))
                complain("{s} cannot have positionals and subcommands at once!", .{typeName(T)});

            inline for (data.fields) |field| {
                if (!isSubcommandUnion(field.type)) continue;

                // Validate subcommand union.
                validateSubcommandUnion(T, @typeInfo(field.type).optional.child);
            }
        },
        else => complain("{s} was not a struct. This is a bug.", .{typeName(T)}),
    }
}

fn validateSubcommandUnion(comptime T: type, comptime F: type) void {
    switch (@typeInfo(F)) {
        .@"union" => |uni| {
            if (uni.tag_type == null)
                complain("{s}: subcommand union must be tagged!", .{typeName(T)});

            inline for (uni.fields) |f| {
                switch (@typeInfo(f.type)) {
                    .@"struct" => validateStruct(f.type),
                    .void => {},
                    else => complain("{s}: subcommand union tag {s} should be void or struct.", .{ typeName(T), f.name }),
                }
            }

            if (@hasDecl(F, "help"))
                validateSubcommandHelp(F);
        },
        else => complain("{s}: unexpected {s} where union(enum) was expected. This may be a bug.", .{ typeName(T), typeName(F) }),
    }
}

/// Validates a `help` decl on a subcommand union: entries are keyed by
/// subcommand name and hold only a `desc`, e.g.
///
/// ```zig
/// pub const help = .{
///     .daemon = .{ .desc = "Run the daemon" },
/// };
/// ```
fn validateSubcommandHelp(comptime U: type) void {
    const help = U.help;
    const Help = @TypeOf(help);

    if (@typeInfo(Help) != .@"struct")
        complain("{s}.help must be a struct value, e.g. `pub const help = .{{ ... }};`", .{typeName(U)});

    inline for (@typeInfo(Help).@"struct".fields) |hf| {
        if (!@hasField(U, hf.name))
            complain("{s}.help got invalid subcommand name: {s}", .{ typeName(U), hf.name });

        const entry = @field(help, hf.name);
        const Entry = @TypeOf(entry);

        if (@typeInfo(Entry) != .@"struct" or !@hasField(Entry, "desc"))
            complain("{s}.help.{s} should be a struct: .{{ .desc = \"...\" }}", .{ typeName(U), hf.name });

        if (!isString(@TypeOf(entry.desc)))
            complain("{s}.{s} help description should be a string!", .{ typeName(U), hf.name });

        // Defaults make no sense for subcommands, so only desc is recognized.
        if (@typeInfo(Entry).@"struct".fields.len > 1)
            complain("{s}.{s} help has unknown fields. Only `desc` is recognized for subcommands.", .{ typeName(U), hf.name });
    }
}

/// Returns true if U is a subcommand union. Performs no validation, just ?union.
pub fn isSubcommandUnion(comptime U: type) bool {
    return switch (@typeInfo(U)) {
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .@"union" => true,
            else => false,
        },
        else => false,
    };
}

fn validateField(
    comptime T: type,
    comptime name: [:0]const u8,
    got_union: *bool,
) void {
    // Used for recursive calls. Child structs can of course have their own
    // subcommands.
    var got_union_nested = false;

    switch (@typeInfo(T)) {
        .@"union" => {
            complain("{s}: subcommand union {s} must be optional!", .{ typeName(T), name });
        },
        .bool, .int => {},
        // Read as tag name, TagName or the backing integer.
        .@"enum" => {},
        .@"struct" => {
            if (!@hasDecl(T, "parse")) {
                complain("Custom type {s} for {s} is currently not supported without a parse decl!", .{ typeName(T), name });
            }
        },
        .optional => |opt| {
            if (@typeInfo(opt.child) == .optional)
                complain("{s}: nested optionals are not supported.", .{name});

            if (@typeInfo(opt.child) == .@"union") {
                if (got_union.*)
                    complain("{s}: unexpected union. Only one is allowed.", .{typeName(T)});

                got_union.* = true;

                return;
            }
        },
        .pointer => |ptr| validatePtr(T, ptr, name),
        .array => |arr| {
            if (std.meta.sentinel(T)) |s| {
                if (arr.child != u8 or s != 0)
                    complain("{s}: only 0 sentinels on u8 arrays are supported.", .{name});
            }

            validateField(arr.child, name, &got_union_nested);

            switch (@typeInfo(arr.child)) {
                .array, .pointer => complain(
                    \\{s}: Nested sequences are not permitted, except [][]const u8,
                    \\but got [{d}]{s}. Consider using a struct with a parse method.
                , .{ name, arr.len, @typeName(arr.child) }),
                // Presumably handled by validateField.
                else => {},
            }
        },
        else => complain("{s} has unsupported type {s}.\nConsider defining .parse(ctx: *Cli.ValueCtx) !T on your type.", .{ name, @typeName(T) }),
    }
}

fn validatePtr(comptime T: type, comptime ptr: Type.Pointer, comptime name: [:0]const u8) void {
    if (ptr.size != .slice)
        complain("{s} is not a slice!", .{name});

    if (ptr.is_allowzero or ptr.is_volatile)
        complain("{s} is not a usable pointer type ({s})!", .{ name, @typeName(T) });

    // Allow null-terminated slices, but only for strings.
    if (std.meta.sentinel(T)) |s| {
        if (ptr.child != u8 or s != 0)
            complain("{s}: only 0 sentinels on u8 slices are supported.", .{name});
    }

    // []u8 and friends are strings; anything else is a list of readable values.
    if (ptr.child == u8) return;

    var got_union = false;
    validateField(ptr.child, name, &got_union);

    if (got_union)
        complain("{s}: subcommand unions are not allowed inside lists!", .{name});
}

/// TODO: Allow repeated positionals only if output type is a slice or array?
fn validatePositionals(comptime T: type) void {
    const positionals = @field(T, "positionals");
    const Positionals = @TypeOf(positionals);

    if (@hasField(Positionals, "help") or @hasField(Positionals, "h")) {
        complain("{s} positionals contains field for reserved help flag!", .{typeName(T)});
    }

    const info = @typeInfo(Positionals).@"struct";

    if (!info.is_tuple)
        complain("{s}.positionals: this should be a tuple!\ni.e. positionals = .{ .name, .public_key, .favourite_colour }", .{});

    inline for (info.fields, 0..) |pf, idx| {
        // i.e. .@"0" = .bob, this would give us .bob as @EnumLiteral().
        const field = @field(positionals, pf.name);

        if (@TypeOf(field) != @EnumLiteral())
            complain("{s} positional {s} should be of type @EnumLiteral(), i.e. positionals = .{ .field, .next_field }", .{ typeName(T), pf.name });

        const field_name = @tagName(field);

        if (!@hasField(T, @tagName(field)))
            complain("{s}.positionals: got non existant field {s}", .{ typeName(T), @tagName(field) });

        validatePositionalFieldType(T, field_name, info.fields.len, idx);
    }
}

/// True if a field is of type []T for any T that is not u8.
/// For obvious reasons these are only allowed in the last slot.
fn isVariadicPositional(comptime T: type, comptime field_name: [:0]const u8) bool {
    return switch (@typeInfo(@FieldType(T, field_name))) {
        .pointer => |ptr| (ptr.size == .slice) and (ptr.child != u8),
        else => false,
    };
}

fn helpHasDefault(comptime T: type, comptime field_name: [:0]const u8) bool {
    if (!@hasDecl(T, "help")) return false;
    const help = T.help;
    if (!@hasField(@TypeOf(help), field_name)) return false;

    return @hasField(@TypeOf(@field(help, field_name)), "default");
}

fn validatePositionalFieldType(comptime T: type, comptime field_name: [:0]const u8, comptime n_fields: usize, idx: usize) void {
    const Field = @FieldType(T, field_name);

    if (idx != n_fields - 1 and isVariadicPositional(T, field_name)) {
        complain("{s} variadic positionals ({s}) are only allowed in the last slot!", .{ typeName(T), field_name });
    }

    if (idx != n_fields - 1 and helpHasDefault(T, field_name)) {
        complain("{s}: defaults are only allowed for trailing positionals but default was set for {s}!", .{ typeName(T), field_name });
    }

    // A valueless positional is meaningless: bools stay as flags.
    const Unwrapped = switch (@typeInfo(Field)) {
        .optional => |opt| opt.child,
        else => Field,
    };

    if (@typeInfo(Unwrapped) == .bool)
        complain("{s}.{s}: bool positionals are not allowed. Use a flag instead.", .{ typeName(T), field_name });

    var got_union = false;
    validateField(Field, typeName(T) ++ "." ++ field_name, &got_union);

    if (got_union)
        complain("{s}.{s}: the subcommand union cannot be a positional!", .{ typeName(T), field_name });
}

fn validateFlags(comptime T: type, _: []const Type.StructField) void {
    const Flags = @TypeOf(T.flags);
    const flags = @typeInfo(Flags).@"struct";

    if (flags.is_tuple)
        complain("{s}: flags should be a struct with named fields!", .{typeName(T)});

    if (@hasField(Flags, "help") or @hasField(Flags, "h")) {
        complain("{s}: flags contains entry for reserved help flag!", .{typeName(T)});
    }

    // Shorts must be unique across the whole struct, so the set lives out here.
    comptime var seen_shorts: []const u8 = &.{};

    for (flags.fields) |f| {
        if (!@hasField(T, f.name))
            complain("{s}.flags: unknown field name reference \"{s}\"", .{ typeName(T), f.name });

        if (isSubcommandUnion(@FieldType(T, f.name)))
            complain("{s}.flags.{s}: the subcommand union is not a flag!", .{ typeName(T), f.name });

        if (@hasDecl(T, "positionals")) {
            for (T.positionals) |p| {
                if (std.mem.eql(u8, @tagName(p), f.name))
                    complain("{s}.flags.{s}: positionals cannot have flag settings!", .{ typeName(T), f.name });
            }
        }

        // Check if this is a struct.
        const field = @field(T.flags, f.name);
        const Field = @TypeOf(field);

        switch (@typeInfo(Field)) {
            .@"struct" => |s| {
                if (validateFlagsField(T, f.name, s)) |short| {
                    if (std.mem.indexOfScalar(u8, seen_shorts, short) != null)
                        complain("{s}: duplicate flag short field '{c}' for field {s}", .{ typeName(T), short, f.name });

                    seen_shorts = seen_shorts ++ .{short};
                }
            },
            else => complain("{s}.flags.{s}: This should be a struct! i.e. .field = .{ .short = 'f' }", .{ typeName(T), f.name }),
        }
    }
}

/// Returns the short char if the entry declares one.
fn validateFlagsField(comptime T: type, comptime field_name: [:0]const u8, comptime s: Type.Struct) ?u8 {
    var short: ?u8 = null;

    inline for (s.fields) |f| {
        if (std.mem.eql(u8, f.name, "short")) {
            if (f.type != u8 and f.type != comptime_int)
                complain("{s}: flags short field for {s} should be a char. TODO: support unicode codepoints", .{ typeName(T), field_name });

            const c: u8 = @field(@field(T.flags, field_name), "short");

            if (!std.ascii.isAlphanumeric(c))
                complain("{s}: flags short field for {s} should be alphanumeric!", .{ typeName(T), field_name });

            if (c == 'h')
                complain("{s}: flags short field for {s} is reserved for -h/--help!", .{ typeName(T), field_name });

            short = c;
        } else {
            // Catch typos like `shrot`: only short is known.
            complain("{s}.flags.{s} has unknown field \"{s}\". Only `short` is recognized.", .{ typeName(T), field_name, f.name });
        }
    }

    return short;
}

// Passing tests for correct inputs only: invalid inputs `complain` at comptime,
// which cannot be caught from a test.

/// A stand-in for custom types like Cli.IpAddress.
const TestAddr = struct {
    host: []const u8 = "",
    port: u16 = 0,

    pub fn parse(ctx: anytype) !TestAddr {
        _ = ctx;
        return .{};
    }
};

test "empty struct" {
    validate(struct {});
}

test "scalar and string flags" {
    validate(struct {
        verbose: bool = false,
        retries: u32 = 3,
        offset: i64 = -1,
        name: []const u8 = "",
        config: ?[]const u8 = null,
        tag: [:0]const u8 = "",
        id: [8]u8 = @splat(0),
    });
}

test "enum and custom parse-decl flags" {
    validate(struct {
        const Colour = enum { auto, always, never };

        colour: Colour = .auto,
        maybe_colour: ?Colour = null,
        addr: TestAddr = .{},
        maybe_addr: ?TestAddr = null,
    });
}

test "list flags" {
    validate(struct {
        ports: []const u16 = &.{},
        names: []const []const u8 = &.{},
        counts: [4]u32 = @splat(0),
    });
}

test "flags decl with shorts" {
    // Shorts on plain flags, coexisting with positionals on the same struct.
    validate(struct {
        name: []const u8,
        config_path: ?[]const u8 = null,
        verbose: bool = false,

        pub const positionals = .{.name};

        pub const flags = .{
            .config_path = .{ .short = 'c' },
            .verbose = .{ .short = 'v' },
        };
    });
}

test "help decl with usage and defaults" {
    validate(struct {
        const Colour = enum { auto, always, never };

        verbose: bool = false,
        colour: Colour = .auto,
        config: ?[]const u8 = null,
        limit: u32 = 10,

        pub const help = .{
            .usage = "usage: test [options]",
            .verbose = .{ .desc = "Log harder", .default = false },
            .colour = .{ .desc = "When to use colour", .default = .auto },
            .config = .{ .desc = "Path to the config file", .default = "~/.config/test" },
            .limit = .{ .desc = "Maximum entries", .default = 10 },
        };
    });
}

test "positionals: single required" {
    validate(struct {
        name: []const u8,

        pub const positionals = .{.name};
    });
}

test "positionals: required, optional and flags mixed" {
    validate(struct {
        name: []const u8,
        pubkey: []const u8,
        alias: ?[]const u8 = null,
        force: bool = false,

        pub const positionals = .{ .name, .pubkey, .alias };
    });
}

test "positionals: typed slots and variadic tail" {
    validate(struct {
        port: u16,
        files: []const []const u8 = &.{},

        pub const positionals = .{ .port, .files };
    });
}

test "subcommands: simple subcommand router" {
    validate(struct {
        verbose: bool = false,

        command: ?union(enum) {
            run: struct {
                fast: bool = false,
            },
            version: void,
        } = null,
    });
}

test "subcommands: nested tree with positionals, help and custom types" {
    const PeerAdd = struct {
        name: []const u8,
        pubkey: []const u8,
        force: bool = false,

        pub const positionals = .{ .name, .pubkey };

        pub const help = .{
            .name = .{ .desc = "Display name for the peer" },
            .pubkey = .{ .desc = "The peer's public key" },
            .force = .{ .desc = "Overwrite an existing peer", .default = false },
        };
    };

    const PeerOpts = struct {
        action: ?union(enum) {
            add: PeerAdd,
            remove: struct {
                name: []const u8,

                pub const positionals = .{.name};
            },
            list: void,

            pub const help = .{
                .add = .{ .desc = "Add a new peer" },
                .list = .{ .desc = "List known peers" },
            };
        } = null,
    };

    const DaemonOpts = struct {
        bind_addr: ?TestAddr = null,
        data_dir: ?[]const u8 = null,

        pub const help = .{
            .bind_addr = .{ .desc = "The address:port to bind to" },
            .data_dir = .{ .desc = "Set a path to the data directory" },
        };
    };

    const Root = struct {
        verbose: bool = false,
        config: ?[]const u8 = null,

        command: ?union(enum) {
            daemon: DaemonOpts,
            peer: PeerOpts,
        } = null,

        pub const help = .{
            .usage = "usage: tool [options] <command> [command options]",
            .verbose = .{ .desc = "Log harder", .default = false },
            .config = .{ .desc = "Path to the config file" },
            .command = .{ .desc = "The subcommand to run" },
        };
    };

    validate(Root);
}

test "positionals: trailing may have default" {
    const Positionals = struct {
        name_one: []const u8,
        name_two: []const u8 = "Bob",

        const Self = @This();

        pub const help = .{
            // Unfortunately there will be some duplication between field
            // defaults and the help section. This should be fixed later.
            .name_two = .{ .desc = "The second name.", .default = "Bob" },
        };

        pub const positionals = .{ .name_one, .name_two };
    };

    validate(Positionals);
}

// Tests below this comment should cause a compiler error.
const failing_tests = false;

test "disallow positionals and subcommands" {
    if (!failing_tests) return error.SkipZigTest;

    const Positionals = struct {
        name_one: []const u8,
        name_two: []const u8 = "Bob",
        cmd: ?union(enum) { do_thing: void },

        const Self = @This();

        pub const help = .{
            .name_two = .{ .desc = "The second name.", .default = "Bob" },
        };

        pub const positionals = .{ .name_one, .name_two };
    };

    validate(Positionals);
}
