const std = @import("std");



pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_options = b.addOptions();

    exe_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    // TODO: Setup CI and have it pass this.
    exe_options.addOption(?[]const u8, "git_rev", null);

    const parseargv = b.dependency("parseargv", .{
        .target = target,
        .optimize = optimize,
    });
    const known_folders = b.dependency("known_folders", .{});
    const serde = b.dependency("serde", .{
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
    });

    exe.root_module.addImport("known-folders", known_folders.module("known-folders"));
    exe.root_module.addImport("serde", serde.module("serde"));
    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));

    exe.root_module.addImport("clipboard", clipboard.module("clipboard"));
    exe.root_module.addImport("argv", parseargv.module("parseargv"));

    exe.root_module.addOptions("options", exe_options);

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "zclip",
        .root_module = exe.root_module,
    });

    const check = b.step("check", "Check if zclip application compiles.");
    check.dependOn(&exe_check.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
