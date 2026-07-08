const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// I should add pretty error reporting and stuff like that.
/// Report to *Io.Writer, File. Maybe get some colour codes in there
/// if supported/desired. This should probably respect the common
/// envvars for disabling colouring.
///
/// Ensure you call `.deinit` once done with the data.
const Diagnostics = struct {
    message: []const u8,

    pub fn deinit(diag: *Diagnostics, ctx: *ParseCtx) void {
        ctx.arena.allocator().free(diag.message);
    }
};

const ArgsList = std.ArrayList([]const u8);

/// # Parse Context
///
/// Parsing context, used for basic types and can be used to implement
/// `parse(ctx: *ParseCtx) !T` for custom T.
///
/// # Notes
///
/// Note that parse is guaranteed not to be called if there are no
/// arguments left to parse.
const ParseCtx = struct {
    arena: ArenaAllocator,
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
        if (self.idx == self.args.items.len) {
            self.finished = true;
            return &.{};
        }

        const arg = self.args.items[self.idx];

        self.idx += 1;

        return arg;
    }

    /// Initialises a `ParseCtx`. Pass `diag` if you want error reporting.
    pub fn init(alloc: Allocator, args: ArgsList, diag: ?*Diagnostics) ParseCtx {
        return .{
            .arena = .init(alloc),
            .args = args,
            .diag = diag,
        };
    }
};
