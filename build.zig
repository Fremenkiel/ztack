//! Build steps for ztack. `docs/LAYOUT.md` lists each step. Logic goes into `src/scripts/`.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    const version = builtin.zig_version;
    const pinned = version.major == 0 and version.minor == 16 and version.patch == 0;
    if (!pinned) @compileError("ztack needs Zig 0.16.0, use ./zig/zig build");
}

pub fn build(b: *std.Build) void {
    const steps = .{
        .run = b.step("run", "Build and start ztack"),
        .test_all = b.step("test", "Run unit tests and tidy"),
        .test_unit = b.step("test:unit", "Run unit tests only"),
        .test_tidy = b.step("test:tidy", "Check the mechanical style rules"),
        .test_fmt = b.step("test:fmt", "Make sure that zig fmt --check passes"),
        .scripts = b.step("scripts", "Run a script from src/scripts.zig"),
        .ci = b.step("ci", "Run every step that CI runs"),
    };
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ztack = b.addExecutable(.{
        .name = "ztack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(ztack);
    const ztack_run = b.addRunArtifact(ztack);
    ztack_run.step.dependOn(b.getInstallStep());
    if (b.args) |arguments| ztack_run.addArgs(arguments);
    steps.run.dependOn(&ztack_run.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    steps.test_unit.dependOn(&b.addRunArtifact(unit_tests).step);

    const scripts = b.addExecutable(.{
        .name = "scripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scripts.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const scripts_run = b.addRunArtifact(scripts);
    scripts_run.setCwd(b.path("."));
    if (b.args) |arguments| scripts_run.addArgs(arguments);
    steps.scripts.dependOn(&scripts_run.step);

    // Tidy reads the file list from git, so the build cannot cache its result.
    const tidy_run = b.addRunArtifact(scripts);
    tidy_run.setCwd(b.path("."));
    tidy_run.addArg("tidy");
    tidy_run.has_side_effects = true;
    steps.test_tidy.dependOn(&tidy_run.step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
        .exclude_paths = &.{},
        .check = true,
    });
    steps.test_fmt.dependOn(&fmt_check.step);

    steps.test_all.dependOn(steps.test_unit);
    steps.test_all.dependOn(steps.test_tidy);
    steps.ci.dependOn(steps.test_all);
    steps.ci.dependOn(steps.test_fmt);
    steps.ci.dependOn(b.getInstallStep());
}
