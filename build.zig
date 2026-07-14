const std = @import("std");

const Scanner = @import("wayland").Scanner;

const Platform = enum { wayland, windows };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_options = b.addOptions();

    exe_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const git_rev = gitShortRev(b) catch |err| blk: {
        std.log.debug("{t}", .{err});
        break :blk null;
    };
    exe_options.addOption(?[]const u8, "git_rev", git_rev);

    const parseargv = b.dependency("parseargv", .{
        .target = target,
        .optimize = optimize,
    });
    const known_folders = b.dependency("known_folders", .{});
    const serde = b.dependency("serde", .{
        .target = target,
        .optimize = optimize,
    });

    const noisey = b.dependency("noisey", .{
        .target = target,
        .optimize = optimize,
    });

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const clipboard = b.dependency("clipboard", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zclip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    exe.root_module.addImport("known-folders", known_folders.module("known-folders"));
    exe.root_module.addImport("serde", serde.module("serde"));
    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));

    exe.root_module.addImport("noisey", noisey.module("noisey"));
    exe.root_module.addImport("clipboard", clipboard.module("clipboard"));
    exe.root_module.addImport("argv", parseargv.module("parseargv"));

    exe.root_module.addOptions("options", exe_options);

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "zclip",
        .root_module = exe.root_module,
        .use_llvm = true,
        .use_lld = true,
    });

    const check = b.step("check", "Check if zclip application compiles.");
    check.dependOn(&exe_check.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
        .use_llvm = true,
        .use_lld = true,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

/// Returns the short commit hash of the current git HEAD, or errors.
/// This is ok since I handled errors in build.
fn gitShortRev(b: *std.Build) ![]const u8 {
    const io = b.graph.io;
    const alloc = b.allocator;

    var result = std.process.spawn(io, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        .cwd = .{ .dir = .cwd() },
        .stdout = .pipe,
    }) catch return error.ProcessSpawn;

    var stdout = result.stdout orelse return error.NoStdout;
    var stdout_buf: [128]u8 = undefined;
    var file_rdr = stdout.reader(io, &stdout_buf);
    const rdr = &file_rdr.interface;

    const hash = try rdr.allocRemaining(alloc, .unlimited);

    const term = try result.wait(io);
    if (term.exited != 0) return error.GitFailed;

    return std.mem.trim(u8, hash, " \t\r\n");
}
