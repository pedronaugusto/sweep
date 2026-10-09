const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const concerns = modules(b, target, optimize);
    const module = concerns.root;
    try b.modules.put(b.allocator, "sweep", module);
    try b.modules.put(b.allocator, "sweep.glob", concerns.glob);
    try b.modules.put(b.allocator, "sweep.walk", concerns.walk);
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
        }),
    });
    tests.root_module.addImport("sweep.glob", concerns.glob);
    tests.root_module.addImport("sweep.walk", concerns.walk);
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    for ([_]*std.Build.Module{ concerns.glob, concerns.walk }, [_][]const u8{ "glob-tests", "walk-tests" }) |concern, name| {
        const suite = b.addTest(.{ .name = name, .filters = filters, .root_module = concern });
        test_step.dependOn(&b.addRunArtifact(suite).step);
        check.dependOn(&suite.step);
        b.getInstallStep().dependOn(&suite.step);
    }
    check.dependOn(&tests.step);
    check.dependOn(&library.step);
    const domains = b.step("check-domains", "Reject mixed entry identities, counts and capacities");
    for ([_][]const u8{ "index", "capacity" }) |name| {
        const source = b.pathJoin(&.{ "ci", "types", b.fmt("{s}.zig", .{name}) });
        const negative = b.addObject(.{ .name = b.fmt("reject-{s}", .{name}), .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sweep.glob", .module = concerns.glob }},
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
    // The matching and capture APIs also build for a target with no OS.
    const freestanding = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const object = b.addObject(.{
        .name = "sweep-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/freestanding.zig"),
            .target = freestanding,
            .optimize = .small,
            .imports = &.{.{ .name = "sweep.glob", .module = modules(b, freestanding, .small).glob }},
        }),
    });
    b.step("check-freestanding", "Build pure public calls for wasm32-freestanding").dependOn(&object.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
    // The test doubles are shakedown's, a lazy dependency only the tests
    // import. Its error is returned last, so one configure pass asks for it
    // and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        concerns.glob.addImport("shakedown", shakedown.module("shakedown"));
        concerns.walk.addImport("shakedown", shakedown.module("shakedown"));
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
        preflight.addConsumerCheck(b, .{ .package = "sweep", .program = b.path("ci/consumer.zig"), .packages = &.{aegis_dependency}, .modules = &.{ "sweep", "sweep.glob", "sweep.walk" } });
    }
    return needed;
}

/// sweep again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would
/// time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const sweep = modules(b, target, optimize).root;
    // The root already requests this lazy test dependency. If configure
    // needs another pass, the root returns LazyDependencyNeeded below.
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "sweep", .module = sweep }, .{ .name = "shakedown", .module = shakedown.module("shakedown") } }) catch @panic("OOM");
    } else |_| {}
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "sweep", .module = sweep }}) catch @panic("OOM");
}

const Modules = struct { root: *std.Build.Module, glob: *std.Build.Module, walk: *std.Build.Module };

fn modules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) Modules {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const glob = b.createModule(.{ .root_source_file = b.path("src/glob.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} });
    const walk = b.createModule(.{ .root_source_file = b.path("src/walk.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sweep.glob", .module = glob }} });
    const root = b.createModule(.{ .root_source_file = b.path("src/sweep.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "sweep.glob", .module = glob }, .{ .name = "sweep.walk", .module = walk } } });
    return .{ .root = root, .glob = glob, .walk = walk };
}
