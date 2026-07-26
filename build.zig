const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared TUI module (pure Zig, no C deps).
    const tui_mod = b.addModule("tui", .{
        .root_source_file = b.path("tui/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Minimal interactive demo for the TUI foundation.
    const demo = b.addExecutable(.{
        .name = "tui_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tui_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tui", .module = tui_mod },
            },
        }),
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    // Forward args: zig build run-demo -- ...
    if (b.args) |args| {
        run_demo.addArgs(args);
    }

    const run_demo_step = b.step("run-demo", "Run the minimal TUI demo (interactive)");
    run_demo_step.dependOn(&run_demo.step);

    // Placeholder main package binary for `rv` itself (not yet implemented).
    const rv = b.addExecutable(.{
        .name = "rv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tui", .module = tui_mod },
            },
        }),
    });
    b.installArtifact(rv);

    const run_rv = b.addRunArtifact(rv);
    run_rv.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_rv.addArgs(args);
    }
    const run_step = b.step("run", "Run the rv binary (stub until the review TUI lands)");
    run_step.dependOn(&run_rv.step);

    // Unit tests for the TUI module.
    const tui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tui/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tui_tests = b.addRunArtifact(tui_tests);
    const test_step = b.step("test", "Run TUI unit tests");
    test_step.dependOn(&run_tui_tests.step);
}
