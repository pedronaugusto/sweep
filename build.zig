const std = @import("std");

/// What a project that depends on sweep builds: the `sweep` module and its library.
/// The tests, example, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("sweep", .{ .root_source_file = b.path("src/sweep.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    b.installArtifact(b.addLibrary(.{ .name = "sweep", .root_module = module }));
}

/// sweep's development: its tests, example, checks and benchmarks under
/// preflight's gate, with shakedown bound to sweep's aegis. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("sweep", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("sweep");
    const library = package.artifact("sweep");
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{
        .name = "sweep-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
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
            .root_source_file = p.path(source),
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
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sweep", .module = module }} }),
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
            .root_source_file = p.path("ci/freestanding.zig"),
            .target = freestanding,
            .optimize = .small,
            .imports = &.{.{ .name = "sweep", .module = sweepModule(b, freestanding, .small) }},
        }),
    });
    b.step("check-freestanding", "Build pure public calls for wasm32-freestanding").dependOn(&object.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
    // The test doubles are shakedown's, bound to sweep's aegis so one aegis is linked.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    tools.shakedown.useAegis(shakedown, aegis_dependency.module("aegis"));
    tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    tools.preflight.addCi(b, p, .{
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
    tools.preflight.addConsumerCheck(b, p, .{ .package = "sweep", .program = p.path("ci/consumer.zig"), .packages = &.{aegis_dependency}, .modules = &.{"sweep"} });
}

/// sweep again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would
/// time the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("sweep", .{ .target = target, .optimize = optimize }).builder;
    const sweep = sweepModule(b, target, optimize);
    // The same binding as `useAegis`, which only a `dev` has the tools for.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    shakedown.module("shakedown").addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "sweep", .module = sweep }, .{ .name = "shakedown", .module = shakedown.module("shakedown") } }) catch @panic("OOM");
}

fn sweepModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const p = b.dependency("sweep", .{ .target = target, .optimize = optimize }).builder;
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    return b.createModule(.{ .root_source_file = p.path("src/sweep.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} });
}
