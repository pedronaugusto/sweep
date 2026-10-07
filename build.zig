const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("sweep", .{ .root_source_file = b.path("src/sweep.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .name = "sweep-tests",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    check.dependOn(&tests.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sweep", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    const library = b.addLibrary(.{ .name = "sweep", .root_module = module });
    b.installArtifact(library);
    check.dependOn(&library.step);
    check.dependOn(&example.step);
    // The benchmarks: `check` compiles them in the requested mode, and
    // `zig build bench` runs them in ReleaseFast. CI never times them.
    const bench_step = b.step("bench", "Time sweep's own workloads in ReleaseFast (by hand; CI only compiles them)");
    for ([_]std.lang.Optimize{ .fast, optimize }, 0..) |mode, i| {
        const sweep_module = if (i == 0) b.createModule(.{ .root_source_file = b.path("src/sweep.zig"), .target = target, .optimize = mode }) else module;
        const bench = b.addExecutable(.{
            .name = "bench",
            .root_module = b.createModule(.{ .root_source_file = b.path("bench/main.zig"), .target = target, .optimize = mode, .imports = &.{.{ .name = "sweep", .module = sweep_module }} }),
        });
        if (i == 0) {
            const run = b.addRunArtifact(bench);
            run.addPassthruArgs();
            bench_step.dependOn(&run.step);
        } else check.dependOn(&bench.step);
    }
    // No OS calls: the whole package builds for a target with no OS at all.
    const freestanding = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const object = b.addObject(.{
        .name = "sweep-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/freestanding.zig"),
            .target = freestanding,
            .optimize = .small,
            .imports = &.{.{ .name = "sweep", .module = b.createModule(.{ .root_source_file = b.path("src/sweep.zig"), .target = freestanding, .optimize = .small }) }},
        }),
    });
    b.step("check-freestanding", "Build every public call for wasm32-freestanding").dependOn(&object.step);
    // CI wiring is this repository's own. preflight is lazy and only the
    // root build asks for it, so a project depending on sweep neither needs
    // nor fetches it.
    if (b.dep_prefix.len == 0) if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true });
        // A project that depends on sweep by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "sweep", .program = b.path("ci/consumer.zig") });
    };
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
}
