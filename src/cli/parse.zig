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
        ctx.alloc.free(diag.message);
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

    /// Parsers should check `self.finished` after each call to this function.
    /// Errors can be raised if more arguments were expected, for example.
    pub fn takeArg(self: *ParseCtx) []const u8 {
        if (self.finished) return &.{};
        if (self.idx == self.args.len) {
            self.finished = true;
            return &.{};
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