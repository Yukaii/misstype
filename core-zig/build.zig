const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("misstype", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    const run = b.addRunArtifact(bench);
    run.addPassthruArgs();
    b.step("bench", "Decode bench/inputs.tsv (args: <resource dir> <inputs> [repeats])").dependOn(&run.step);

    // Static library: the future home of the misstype.h C ABI.
    const lib = b.addLibrary(.{
        .name = "misstype",
        .linkage = .static,
        .root_module = core,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run core tests").dependOn(&b.addRunArtifact(tests).step);
}
