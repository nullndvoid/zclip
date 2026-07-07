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

//! Generation of static keypairs for authentication between peers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const X25519 = std.crypto.dh.X25519;
const builtin = @import("builtin");

const known = @import("known-folders");

const log = std.log.scoped(.Identity);

const Identity = @This();

private_key: [X25519.secret_length]u8,
public_key: [X25519.public_length]u8,

/// On Windows we rely on the inherited ACL of the user's data directory instead.
const KEYFILE_PERMS: Io.File.Permissions = switch (builtin.os.tag) {
    .windows => .default_file,
    else => @enumFromInt(0o600),
};

const KEYFILE_DIR_PERMS: Io.File.Permissions = switch (builtin.os.tag) {
    .windows => .default_dir,
    else => @enumFromInt(0o700),
};

pub fn fromPath(io: Io, absolute_path: []const u8, quiet: bool) !Identity {
    var keyfile = Io.Dir.openFileAbsolute(io, absolute_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (!quiet)
                    log.err("Private key file not found at {s}.", .{absolute_path});
            },
            else => {
                if (!quiet)
                    log.err("Could not open private key file at {s}. Reason: {t}", .{ absolute_path, err });
            },
        }
        return err;
    };

    try correctPerms(io, keyfile);

    defer keyfile.close(io);

    var rdr_buf: [32]u8 = undefined;
    var key_buf: [32]u8 = undefined;

    var file_rdr = keyfile.reader(io, &rdr_buf);
    const rdr = &file_rdr.interface;

    rdr.readSliceAll(&key_buf) catch |err| {
        switch (err) {
            error.EndOfStream => {
                log.err("Private key in {s} too short! This should be 32 bytes in length.", .{absolute_path});
            },
            else => {
                log.err("Could not read from private key file at {s}. Reason: {t}", .{ absolute_path, err });
            },
        }

        return err;
    };

    return Identity{
        .private_key = key_buf,
        .public_key = try X25519.recoverPublicKey(key_buf),
    };
}

/// Returns the absolute path of zclip's directory inside the well known data
/// directory for this platform. Caller owns the returned memory.
pub fn getWellKnownDir(io: Io, alloc: Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const data_dir_path = known.getPath(io, alloc, environ, .data) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                log.err("Failed to allocate memory for data dir path.", .{});
            },
            // This is being called synchronously.
            error.Canceled => unreachable,
        }

        return err;
    } orelse {
        log.err("Could not find the data directory for your machine. Consider passing an explicit path to your data directory for zclip!", .{});
        return error.DirectoryNotFound;
    };
    defer alloc.free(data_dir_path);

    return std.fmt.allocPrint(alloc, "{s}/zclip", .{data_dir_path});
}

pub fn fromWellKnown(io: Io, alloc: Allocator, environ: *const std.process.Environ.Map, quiet: bool) !Identity {
    const keyfile_dir_path = try getWellKnownDir(io, alloc, environ);
    defer alloc.free(keyfile_dir_path);

    const keyfile_path = try std.fmt.allocPrint(alloc, "{s}/identity", .{keyfile_dir_path});
    defer alloc.free(keyfile_path);

    return try fromPath(io, keyfile_path, quiet);
}

/// If the file is not 0600, this is updated.
fn correctPerms(io: Io, file: Io.File) !void {
    const stat = try file.stat(io);

    switch (@import("builtin").os.tag) {
        .linux, .macos => {
            const mode = stat.permissions.toMode() & 0o7777;

            if (mode == 0o600) {
                return;
            }

            try file.setPermissions(io, @enumFromInt(0o600));

            log.info("Updated permissions on keyfile to 0600.", .{});
        },
        .windows => {
            return;
        },
        else => unreachable,
    }
}

/// Uses the well known data directory to fetch the identity, or saves a newly generated
/// private key in this path if it does not exist. Call this and be done.
pub fn getOrInit(io: Io, alloc: Allocator, data_dir: []const u8) !Identity {
    const identity = fromPath(io, data_dir, true) catch |err| {
        switch (err) {
            error.FileNotFound => {
                const ident = try writeIdentity(io, data_dir);

                const size = std.base64.standard.Encoder.calcSize(ident.public_key.len);
                const buf = try alloc.alloc(u8, size);
                defer alloc.free(buf);

                const b64 = std.base64.standard.Encoder.encode(buf, &ident.public_key);

                log.info("Created new identity keypair. Public key is {s}", .{b64});
                log.info("On subsequent runs, you may call `zclip client ident` to fetch the public key", .{});

                return ident;
            },
            else => {
                log.err("Could not open identity keyfile. Error: {t}", .{err});

                return err;
            },
        }
    };

    return identity;
}

pub fn writeIdentity(io: Io, data_dir: []const u8) !Identity {
    const kp = X25519.KeyPair.generate(io);

    Io.Dir.cwd().createDir(io, data_dir, KEYFILE_DIR_PERMS) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.err("Could not create zclip data directory at {s}. Reason: {t}", .{ data_dir, err });
            return err;
        },
    };

    // Open the keyfile dir and path for writing.
    const keyfile_dir = Io.Dir.cwd().openDir(io, data_dir, .{}) catch |err| {
        log.err("Could not open zclip data directory at {s}. Reason: {t}", .{ data_dir, err });
        return err;
    };
    defer keyfile_dir.close(io);

    const keyfile = keyfile_dir.createFile(io, "identity", .{
        .permissions = KEYFILE_PERMS,
    }) catch |err| {
        log.err("Could not create identity keyfile in {s}. Reason: {t}", .{ data_dir, err });
        return err;
    };
    defer keyfile.close(io);

    var writer_buf: [32]u8 = undefined;

    var file_writer = keyfile.writer(io, &writer_buf);
    const writer = &file_writer.interface;

    writeKey(writer, &kp.secret_key) catch {
        log.err("Could not write private key to {s}/identity. Reason: {t}", .{
            data_dir,
            file_writer.err orelse error.WriteFailed,
        });
        return error.WriteFailed;
    };

    return Identity{
        .private_key = kp.secret_key,
        .public_key = kp.public_key,
    };
}

fn writeKey(writer: *Io.Writer, secret_key: []const u8) !void {
    try writer.writeAll(secret_key);
    try writer.flush();
}
