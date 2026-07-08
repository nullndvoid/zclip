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

fn complain(comptime fmt: [:0]const u8, args: anytype) noreturn {
    @compileError(comptimePrint(fmt, args));
}

/// I want to scan struct fields and check their types are valid as first pass.
/// Then I will worry about the rest later. This will compile error for invalid inputs.
/// Allows tuples in order to handle a list of args with various types.
fn validateStruct(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |data| {
            for (data.fields, 0..) |field, i| {
                const field_name =
                    if (!data.is_tuple)
                        fieldNameStr(T, .{ .f = field.name })
                    else
                        fieldNameStr(T, .{ .i = i });

                if (std.mem.countScalar(u8, field.name, '=') != 0)
                    complain("Field names ({s}) must not contain '='!", .{field_name});

                if (!data.is_tuple and std.mem.countScalar(u8, field.name, ' ') != 0)
                    complain("Field names ({s}) must not contain spaces!", .{field_name});

                validateField(field.type, field_name);
            }
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
        else => complain("{s} has unsupported type {s}.", .{ name, @typeName(T) }),
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
