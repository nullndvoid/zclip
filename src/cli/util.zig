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

const Validate = @import("Validate.zig");

/// The user-facing long flag name for a field: underscores become dashes,
/// e.g. `config_path` matches `--config-path`.
pub fn longName(comptime field: Type.StructField) [:0]const u8 {
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
pub fn shortFor(comptime T: type, comptime field_name: [:0]const u8) ?u8 {
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
pub fn isPositionalSlot(comptime T: type, comptime field_name: [:0]const u8) bool {
    _ = positionalSlot(T, field_name) orelse return false;
    return true;
}

pub fn positionalSlot(comptime T: type, comptime field_name: [:0]const u8) ?usize {
    comptime {
        if (!@hasDecl(T, "positionals")) return null;

        for (T.positionals, 0..) |p, idx| {
            if (std.mem.eql(u8, @tagName(p), field_name)) return idx;
        }

        return null;
    }
}

/// True if the field holds the subcommand union rather than a flag.
pub fn isSubcommand(comptime T: type, comptime field_name: [:0]const u8) bool {
    comptime return Validate.isSubcommandUnion(@FieldType(T, field_name));
}

/// Returns the struct field holding the subcommand union, if any.
/// Validation guarantees there is at most one.
pub fn subcommandField(comptime T: type) ?Type.StructField {
    comptime {
        const idx = subcommandFieldIndex(T) orelse return null;
        return @typeInfo(T).@"struct".fields[idx];
    }
}

pub fn subcommandFieldIndex(comptime T: type) ?usize {
    comptime {
        for (@typeInfo(T).@"struct".fields, 0..) |f, idx| {
            if (Validate.isSubcommandUnion(f.type)) return idx;
        }

        return null;
    }
}

/// Returns the description of the field with name `field_name` if any.
pub fn descriptionOf(comptime T: type, comptime field_name: [:0]const u8) ?[:0]const u8 {
    if (!@hasDecl(T, "help")) return null;

    const Help = @TypeOf(T.help);

    if (!@hasField(Help, field_name)) return null;

    if (!@hasField(@TypeOf(@field(T.help, field_name)), "desc"))
        return null;

    return @field(T.help, field_name).desc;
}
