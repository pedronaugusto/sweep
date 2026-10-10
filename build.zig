const std = @import("std");

pub fn build(b: *std.Build) !void {
    // lazyImport compares every package of the dependency tree at comptime;
    // a large tree runs past the default quota of 1000 branches.
    @setEvalBranchQuota(100_000);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = sweepModule(b, target, optimize);
    try b.modules.put(b.allocator, "sweep", module);
    const aegis_dependency = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const library = b.addLibrary(.{ .name = "sweep", .root_module = module });
    b.installArtifact(library);
    // Everything below is this repository's own: a project depending on
    // sweep builds the module and nothing else, and fetches only its runtime dependency.
    if (b.pkg_hash.len != 0) return;
    const filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{
        .name = "sweep-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "aegis", .module = aegis_dependency.module("aegis") }},
        }),
    });
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    check.dependOn(&library.step);
    const domains = b.step("check-domains", "Reject mixed entry identities, counts and capacities");
    for ([_][]const u8{ "index", "capacity" }) |name| {
        const source = b.pathJoin(&.{ "ci", "types", b.fmt("{s}.zig", .{name}) });
        const negative = b.addObject(.{ .name = b.fmt("reject-{s}", .{name}), .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sweep", .module = module }},
        }) });
        negative.expect_errors = .{ .starts_with = b.fmt("{s}:3:{d}: error: expected type '{s}(", .{ source, @as(u8, if (std.mem.eql(u8, name, "index")) 47 else 72), if (std.mem.eql(u8, name, "index")) "id.Identity" else "units.Bytes" }) };
        domains.dependOn(&negative.step);
    }
    check.dependOn(domains);
    test_step.dependOn(domains);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sweep", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    // The matching and capture APIs also build for a target with no OS: the
    // walk is analysed only where something names it.
    const freestanding = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const object = b.addObject(.{
        .name = "sweep-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/freestanding.zig"),
            .target = freestanding,
            .optimize = .small,
            .imports = &.{.{ .name = "sweep", .module = sweepModule(b, freestanding, .small) }},
        }),
    });
    b.step("check-freestanding", "Build pure public calls for wasm32-freestanding").dependOn(&object.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
    // The test doubles are shakedown's, a lazy dependency only the tests
    // import. Its error is returned last, so one configure pass asks for it
    // and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    // It is bound to sweep's aegis, so one aegis is linked.
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer })) |shakedown| {
        if (b.lazyImport(@This(), "shakedown")) |shakedown_build| shakedown_build.useAegis(shakedown, aegis_dependency.module("aegis"));
        tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |err| needed = err;
    // CI wiring. preflight is lazy and only the root build asks for it.
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            .bench = .{
                .programs = &.{ .{ .name = "bench", .source = "bench/main.zig" }, .{ .name = "normalization", .source = "bench/normalization.zig" }, .{ .name = "adoption", .source = "bench/adoption.zig" } },
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on sweep by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "sweep", .program = b.path("ci/consumer.zig"), .packages = &.{aegis_dependency}, .modules = &.{"sweep"} });
    }
    return needed;
}

/// sweep again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would
/// time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    // lazyImport compares every package of the dependency tree at comptime;
    // a large tree runs past the default quota of 1000 branches.
    @setEvalBranchQuota(100_000);
    const sweep = sweepModule(b, target, optimize);
    // The root already requests this lazy test dependency. If configure
    // needs another pass, the root returns LazyDependencyNeeded below.
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer })) |shakedown| {
        if (b.lazyImport(@This(), "shakedown")) |shakedown_build| shakedown_build.useAegis(shakedown, b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
        return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "sweep", .module = sweep }, .{ .name = "shakedown", .module = shakedown.module("shakedown") } }) catch @panic("OOM");
    } else |_| {}
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "sweep", .module = sweep }}) catch @panic("OOM");
}

fn sweepModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    return b.createModule(.{ .root_source_file = b.path("src/sweep.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} });
}
