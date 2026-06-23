const std = @import("std");

const Scanner = @import("wayland").Scanner;

const Platform = enum { wayland, windows };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const platform = b.option(
        Platform,
        "platform",
        "Target platform",
    ) orelse switch (target.result.os.tag) {
        .linux => Platform.wayland,
        .windows => Platform.windows,
        else => @panic("unsupported platform"),
    };

    var wayland: *std.Build.Module = undefined;
    var windows: *std.Build.Module = undefined;

    switch (platform) {
        .wayland => {
            const scanner = Scanner.create(b, .{});
            wayland = b.createModule(.{ .root_source_file = scanner.result });
            scanner.addCustomProtocol(b.path("protocols/ext-data-control-v1.xml"));
            scanner.addCustomProtocol(b.path("protocols/wlr-data-control-unstable-v1.xml"));

            scanner.generate("ext_data_control_manager_v1", 1);
            scanner.generate("zwlr_data_control_manager_v1", 1);
            scanner.generate("wl_seat", 1);
        },
        .windows => {
            const windows_dep = b.dependency("win32", .{});
            windows = windows_dep.module("win32");
        },
    }

    const options = b.addOptions();
    const exe_options = b.addOptions();

    options.addOption(Platform, "platform", platform);
    exe_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const git_rev = gitShortRev(b) catch |err| blk: {
        std.log.debug("{t}", .{err});
        break :blk null;
    };
    exe_options.addOption(?[]const u8, "git_rev", git_rev);

    const mod = b.addModule("zclip", .{
        .root_source_file = b.path("lib/root.zig"),
        .target = target,
    });

    mod.addOptions("options", options);
    mod.link_libc = true;

    switch (platform) {
        .wayland => {
            mod.addImport("wayland", wayland);
            mod.linkSystemLibrary("wayland-client", .{
                .use_pkg_config = .force,
            });
        },
        .windows => {
            mod.addImport("win32", windows);
            mod.linkSystemLibrary("user32", .{});
        },
    }

    const clap = b.dependency("clap", .{});
    const known_folders = b.dependency("known_folders", .{});
    const toml = b.dependency("toml", .{});

    const exe = b.addExecutable(.{
        .name = "zclip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,

            .imports = &.{
                .{ .name = "zclip", .module = mod },
            },
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addImport("known-folders", known_folders.module("known-folders"));
    exe.root_module.addImport("toml", toml.module("toml"));

    exe.root_module.addOptions("options", exe_options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
        .use_llvm = true,
        .use_lld = true,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

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
    test_step.dependOn(&run_mod_tests.step);
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
