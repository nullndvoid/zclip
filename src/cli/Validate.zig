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
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| arr.child == u8,
                else => false,
            },
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

    // Catch typos like `dsec` or `defualt` without looping: only desc and default are known.
    const known_fields = 1 + @as(usize, @intFromBool(has_default));
    if (@typeInfo(Entry).@"struct".fields.len > known_fields)
        complain("{s}.{s} help has unknown fields. Only `desc` and `default` are recognized.", .{ typeName(T), original.name });

    if (!has_default) return;

    if (@TypeOf(entry.default) != original.type)
        complain(
            "{s}.{s} help default is the wrong type! Expected `{s}` but got `{s}`.",
            .{ typeName(T), original.name, typeName(original.type), typeName(@TypeOf(entry.default)) },
        );
}

pub fn validate(comptime T: type) void {
    comptime validateStruct(T);
}

/// I want to scan struct fields and check their types are valid as first pass.
/// Then I will worry about the rest later. This will compile error for invalid inputs.
/// Allows tuples in order to handle a list of args with various types.
fn validateStruct(comptime T: type) void {
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

                validateField(field.type, field_name);
            }

            if (@hasDecl(T, "help"))
                validateHelp(T, data.fields);
        },
        else => complain("{s} was not a struct. This is a bug.", .{typeName(T)}),
    }
}

fn validateField(comptime T: type, comptime name: [:0]const u8) void {
    switch (@typeInfo(T)) {
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

            validateField(opt.child, name);
        },
        .pointer => |ptr| validatePtr(T, ptr, name),
        .array => |arr| {
            if (std.meta.sentinel(T)) |s| {
                if (arr.child != u8 or s != 0)
                    complain("{s}: only 0 sentinels on u8 arrays are supported.", .{name});
            }

            validateField(arr.child, name);

            switch (@typeInfo(arr.child)) {
                .array, .ptr => complain(
                    \\{s}: Nested sequences are not permitted, except [][]const u8,
                    \\but got [{d}]{s}. Consider using a struct with a parse method.
                , .{ name, arr.len, arr.child }),
                // Presumably handled by validateField.
                else => {},
            }
        },
        else => complain("{s} has unsupported type {s}.\nConsider defining .parse(ctx: *Cli.ParseCtx) !T on your type.", .{ name, @typeName(T) }),
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
    if (ptr.child != u8) validateField(ptr.child, name);
}
