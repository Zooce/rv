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

    // Diff model + unified parser (MVP-0.1).
    const diff_mod = b.addModule("diff", .{
        .root_source_file = b.path("src/diff.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared test temp dirs under `/tmp` (IsolatedTmp). Imported by modules
    // that run fixtures; unused on production paths (see `builtin.is_test`).
    const isolated_tmp_mod = b.addModule("isolated_tmp", .{
        .root_source_file = b.path("src/isolated_tmp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Git subprocess loader + smart default (MVP-0.2).
    const git_mod = b.addModule("git", .{
        .root_source_file = b.path("src/git.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diff", .module = diff_mod },
            .{ .name = "isolated_tmp", .module = isolated_tmp_mod },
        },
    });

    // Flatten Diff → display rows + viewport helpers (MVP-0.3).
    const view_mod = b.addModule("view", .{
        .root_source_file = b.path("src/view.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diff", .module = diff_mod },
        },
    });

    // Comment model + `.rv/reviews/` JSON store (MVP-1).
    const store_mod = b.addModule("store", .{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "isolated_tmp", .module = isolated_tmp_mod },
        },
    });

    // Bundled agent skill install (MVP-2.5).
    const install_skill_mod = b.addModule("install_skill", .{
        .root_source_file = b.path("src/install_skill.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "isolated_tmp", .module = isolated_tmp_mod },
        },
    });

    // Headless CLI: status / list / show / export / install-skill (MVP-2.2+).
    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "store", .module = store_mod },
            .{ .name = "install_skill", .module = install_skill_mod },
        },
    });

    // `rv` binary: full-screen read-only diff review TUI.
    const rv = b.addExecutable(.{
        .name = "rv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tui", .module = tui_mod },
                .{ .name = "diff", .module = diff_mod },
                .{ .name = "git", .module = git_mod },
                .{ .name = "view", .module = view_mod },
                .{ .name = "store", .module = store_mod },
                .{ .name = "cli", .module = cli_mod },
            },
        }),
    });
    b.installArtifact(rv);
    // Bundled skill for `rv install-skill` (prefix/share/rv/skills/rv).
    b.installDirectory(.{
        .source_dir = b.path("skills/rv"),
        .install_dir = .prefix,
        .install_subdir = "share/rv/skills/rv",
    });

    const run_rv = b.addRunArtifact(rv);
    run_rv.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_rv.addArgs(args);
    }
    const run_step = b.step("run", "Run rv (full-screen diff review TUI)");
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

    // Reuse the same module graph as the library import (not a second root).
    const diff_tests = b.addTest(.{
        .root_module = diff_mod,
    });
    const run_diff_tests = b.addRunArtifact(diff_tests);

    const git_tests = b.addTest(.{
        .root_module = git_mod,
    });
    const run_git_tests = b.addRunArtifact(git_tests);

    const view_tests = b.addTest(.{
        .root_module = view_mod,
    });
    const run_view_tests = b.addRunArtifact(view_tests);

    const store_tests = b.addTest(.{
        .root_module = store_mod,
    });
    const run_store_tests = b.addRunArtifact(store_tests);

    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const install_skill_tests = b.addTest(.{
        .root_module = install_skill_mod,
    });
    const run_install_skill_tests = b.addRunArtifact(install_skill_tests);

    const test_step = b.step("test", "Run unit tests (TUI + diff + git + view + store + cli + install_skill)");
    test_step.dependOn(&run_tui_tests.step);
    test_step.dependOn(&run_diff_tests.step);
    test_step.dependOn(&run_git_tests.step);
    test_step.dependOn(&run_view_tests.step);
    test_step.dependOn(&run_store_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_install_skill_tests.step);
}
