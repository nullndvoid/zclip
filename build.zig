const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const platform = b.option(
        enum { wayland, windows },
        "platform",
        "Target platform",
    ) orelse switch (@import("builtin").os.tag) {
        .linux => .wayland,
        .windows => .windows,
        else => @panic("unsupported platform"),
    };

    var wayland: *std.Build.Module = undefined;

    if (platform == .wayland) {
        const scanner = Scanner.create(b, .{});
        wayland = b.createModule(.{ .root_source_file = scanner.result });
        scanner.addCustomProtocol(b.path("protocols/ext-data-control-v1.xml"));
        scanner.addCustomProtocol(b.path("protocols/wlr-data-control-unstable-v1.xml"));

        scanner.generate("ext_data_control_manager_v1", 1);
        scanner.generate("zwlr_data_control_manager_v1", 1);
        scanner.generate("wl_seat", 1);
    }

    const options = b.addOptions();
    options.addOption(@TypeOf(platform), "platform", platform);

    const mod = b.addModule("zclip", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addOptions("options", options);
    mod.link_libc = true;

    if (platform == .wayland) {
        mod.addImport("wayland", wayland);
        mod.linkSystemLibrary("wayland-client", .{
            .use_pkg_config = .force,
        });
    }

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
