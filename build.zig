const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_options = b.addOptions();

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

    exe_options.addOption([:0]const u8, "version", try getVersionString(b));

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

/// Taken from Zig's own build script.
fn getVersionString(b: *std.Build) ![:0]const u8 {
    const arena = b.graph.arena;

    const zon_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

    const opt_version_string = b.option([]const u8, "version-string", "Override Zig version string. Default is to find out with git.");
    const version_slice = if (opt_version_string) |version| version else v: {
        if (!std.process.can_spawn) {
            std.debug.print("error: version info cannot be retrieved from git. Zig version must be provided using -Dversion-string\n", .{});
            std.process.exit(1);
        }

        // Ensure git version changes get picked up.
        git: {
            const io = b.graph.io;
            const git_file = b.root.openFile(io, ".git", .{ .allow_directory = false }) catch |err| switch (err) {
                error.IsDir => {
                    b.dependOnFileContents(b.path(".git/logs/HEAD"));
                    break :git;
                },
                else => |e| return e,
            };
            defer git_file.close(io);
            var line_buffer: ["gitdir: ".len + std.Io.Dir.max_path_bytes + 1]u8 = undefined;
            var git_file_reader = git_file.reader(io, &line_buffer);
            if (std.mem.cutPrefix(u8, std.mem.trimEnd(u8, try git_file_reader.interface.allocRemaining(
                arena,
                .limited("gitdir: ".len + std.Io.Dir.max_path_bytes + "\r\n".len),
            ), "\r\n"), "gitdir: ")) |git_dir| {
                const head_file = b.pathJoin(&.{ git_dir, "logs", "HEAD" });
                b.dependOnFileContents(if (std.Io.Dir.path.isAbsolute(head_file))
                    b.graph.cwdRelativePath(head_file)
                else
                    b.path(head_file));
            }
        }

        const version_string = b.fmt(
            "{d}.{d}.{d}",
            .{ zon_version.major, zon_version.minor, zon_version.patch },
        );

        var code: u8 = undefined;
        const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
            "git",
            "-C", b.fmt("{f}", .{b.root}), // affects the --git-dir argument
            "--git-dir", ".git", // affected by the -C argument
            "describe", "--match",    "*.*.*", //
            "--tags",   "--abbrev=9",
        }, &code, .ignore) catch {
            break :v version_string;
        };
        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.countScalar(u8, git_describe, '-')) {
            0 => {
                // Tagged release version (e.g. 0.10.0).
                if (!std.mem.eql(u8, git_describe, version_string)) {
                    std.debug.print("Zig version '{s}' does not match Git tag '{s}'\n", .{ version_string, git_describe });
                    std.process.exit(1);
                }
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
                var it = std.mem.splitScalar(u8, git_describe, '-');
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
                if (zon_version.order(ancestor_ver) != .gt) {
                    std.debug.print("Zig version '{f}' must be greater than tagged ancestor '{f}'\n", .{ zon_version, ancestor_ver });
                    std.process.exit(1);
                }

                // Check that the commit hash is prefixed with a 'g' (a Git convention).
                if (commit_id.len < 1 or commit_id[0] != 'g') {
                    std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                    break :v version_string;
                }

                // The version is reformatted in accordance with the https://semver.org specification.
                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                break :v version_string;
            },
        }
    };

    const version = try arena.dupeSentinel(u8, version_slice, 0);

    return version;
}
