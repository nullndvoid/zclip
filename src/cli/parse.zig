const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Type = std.builtin.Type;

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

pub fn parse(comptime T: type, args: []const [:0]const u8, alloc: Allocator, diag: ?*Diagnostics) ParseError!void {
    Validate.validate(T);

    const mode = Validate.positionalOrSubcom(T);

    std.log.debug("mode: {t}", .{mode});

    const ctx = ParseCtx.init(alloc, args, diag);
    _ = ctx; // autofix
}

/// Match `--name` (already stripped of dashes, before any '=') to a field index.
fn matchLong(comptime T: type, name: []const u8) ?usize {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |f, idx| {
        comptime if (isPositionalSlot(T, f.name)) continue;
        comptime if (subcommandField(T)) |u|
            if (std.mem.eql(u8, f.name, u.name)) continue;

        if (std.mem.eql(u8, name, comptime longName(f))) return idx;
    }
    return null;
}

/// Match a single short flag char to a field index.
/// Positionals and the subcommand union can never have shorts (validated).
fn matchShort(comptime T: type, c: u8) ?usize {
    const fields = @typeInfo(T).@"struct".fields;

    inline for (fields, 0..) |f, idx| {
        if (comptime shortFor(T, f.name)) |short| {
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

                    try tail.append(ctx.alloc, try parseValue(Elem, ctx, arg, comptime longName(last_field)));

                    pos_idx += 1;
                    continue;
                }
            }

            if (pos_idx >= indices.len)
                return fail(ctx, error.UnexpectedArgument, "unexpected argument \"{s}\"", .{arg});

            try assignField(T, &result, &seen_fields, indices[pos_idx], ctx, arg, null);
            pos_idx += 1;
        } else if (comptime mode == .Subcommand) {
            // TODO: match against the union tags and recurse.
            return fail(ctx, error.UnknownCommand, "unknown command \"{s}\"", .{arg});
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
        comptime if (subcommandField(T)) |u|
            if (std.mem.eql(u8, f.name, u.name)) continue;

        const required = comptime (f.defaultValue() == null and @typeInfo(f.type) != .optional);
        if (required and !seen_fields.isSet(i)) {
            if (comptime isPositionalSlot(T, f.name))
                return fail(ctx, error.MissingPositional, "missing required positional <{s}>", .{f.name});

            return fail(ctx, error.MissingRequiredFlag, "missing required flag --{s}", .{comptime longName(f)});
        }
    }

    return result;
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
        if (i == idx) {
            const disp = display orelse comptime longName(f);

            @field(result, f.name) = try parseValue(f.type, ctx, eq_value, disp);
            seen.set(i);

            return;
        }
    }

    // idx came from a matcher so this should never be hit.
    unreachable;
}

// argv_0 arg/positional/subcom...
// if we see -- and not quoted, parse long flags for T
// same goes for short flags
// if a short flag is binary, next char should be a space/another flag short char.
//

// We can take:
// -s (short flag)
// --long-flag
// subcommand/positional (select based on current T)
// spaces? Should be handled by shell args.

/// The user-facing long flag name for a field: underscores become dashes,
/// e.g. `config_path` matches `--config-path`.
fn longName(comptime field: Type.StructField) [:0]const u8 {
    comptime {
        var out: [field.name.len:0]u8 = @splat(0);

        for (field.name, 0..) |c, i| {
            out[i] = if (c == '_') '-' else c;
        }

        const frozen = out;
        return &frozen;
    }
}

/// The short flag char declared for a field in the `flags` decl, if any.
fn shortFor(comptime T: type, comptime field_name: [:0]const u8) ?u8 {
    comptime {
        if (!@hasDecl(T, "flags")) return null;
        if (!@hasField(@TypeOf(T.flags), field_name)) return null;

        const entry = @field(T.flags, field_name);
        if (!@hasField(@TypeOf(entry), "short")) return null;

        return entry.short;
    }
}

/// True if the field is listed in the `positionals` decl, meaning it is
/// filled by position rather than by flag.
fn isPositionalSlot(comptime T: type, comptime field_name: [:0]const u8) bool {
    comptime {
        if (!@hasDecl(T, "positionals")) return false;

        for (T.positionals) |p| {
            if (std.mem.eql(u8, @tagName(p), field_name)) return true;
        }

        return false;
    }
}

/// Returns the struct field holding the subcommand union, if any.
/// Validation guarantees there is at most one.
fn subcommandField(comptime T: type) ?Type.StructField {
    comptime {
        for (@typeInfo(T).@"struct".fields) |f| {
            if (Validate.isSubcommandUnion(f.type)) return f;
        }

        return null;
    }
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

    try std.testing.expectEqualStrings("config-path", comptime longName(fields[0]));
    try std.testing.expectEqualStrings("verbose", comptime longName(fields[1]));

    try std.testing.expectEqual(@as(?u8, 'c'), comptime shortFor(T, "config_path"));
    try std.testing.expectEqual(@as(?u8, null), comptime shortFor(T, "verbose"));
    try std.testing.expectEqual(@as(?u8, null), comptime shortFor(P, "name"));

    try std.testing.expect(comptime isPositionalSlot(P, "name"));
    try std.testing.expect(comptime !isPositionalSlot(P, "force"));
    try std.testing.expect(comptime !isPositionalSlot(T, "name"));

    try std.testing.expectEqualStrings("command", comptime (subcommandField(T) orelse unreachable).name);
    try std.testing.expect(comptime subcommandField(P) == null);
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
