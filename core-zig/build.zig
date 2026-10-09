const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("misstype", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // libm for bit-identical learned costs (channel.zig); malloc for the C ABI.
        .link_libc = true,
    });
    addUnicode(b, core);

    // The C ABI of Sources/CMisstype/include/misstype.h.
    const lib = b.addLibrary(.{
        .name = "MisstypeCAPI",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addUnicode(b, lib.root_module);
    const install_lib = b.addInstallArtifact(lib, .{});
    b.getInstallStep().dependOn(&install_lib.step);

    // Replay driver (tests/replay) linked against the Zig library.
    const replay = b.addExecutable(.{
        .name = "replay",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    replay.root_module.addCSourceFile(.{ .file = b.path("../tests/replay/replay.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    replay.root_module.addIncludePath(b.path("../Sources/CMisstype/include"));
    replay.root_module.linkLibrary(lib);
    b.installArtifact(replay);

    // Differential + latency harness against the Swift decoder (bench/).
    const bench = b.addExecutable(.{
        .name = "misstype-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "misstype", .module = core }},
        }),
    });
    b.installArtifact(bench);
    const parity = b.addExecutable(.{
        .name = "misstype-parity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parity.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "misstype", .module = core }},
        }),
    });
    b.installArtifact(parity);
    const ctl = b.addExecutable(.{
        .name = "misstypectl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ctl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "misstype", .module = core }},
        }),
    });
    const install_ctl = b.addInstallArtifact(ctl, .{});
    b.getInstallStep().dependOn(&install_ctl.step);
    const dev = b.addExecutable(.{
        .name = "misstype-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "misstype", .module = core }},
        }),
    });
    b.installArtifact(dev);
    const linux = b.step("linux", "Build only the Linux shipping library and CLI");
    linux.dependOn(&install_lib.step);
    linux.dependOn(&install_ctl.step);
    const run = b.addRunArtifact(bench);
    run.addPassthruArgs();
    b.step("bench", "Decode bench/inputs.tsv (args: <resource dir> <inputs> [repeats])").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run core tests").dependOn(&b.addRunArtifact(tests).step);
}

fn addUnicode(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{ .file = b.path("../third_party/utf8proc/utf8proc.c"), .flags = &.{"-DUTF8PROC_STATIC"} });
    module.addIncludePath(b.path("../third_party/utf8proc"));
}
