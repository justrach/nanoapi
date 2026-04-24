const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("turboapi_core", .{
        .target = target,
        .optimize = optimize,
    });
    const core_mod = core_dep.module("turboapi-core");

    const mod = b.addModule("nanoapi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("turboapi-core", core_mod);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addImport("turboapi-core", core_mod);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const bench = b.addExecutable(.{
        .name = "dispatch_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/dispatch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench.root_module.addImport("nanoapi", mod);

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);

    const bench_step = b.step("bench", "Run dispatch benchmark");
    bench_step.dependOn(&run_bench.step);

    const http_server = b.addExecutable(.{
        .name = "nano_http_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/http_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    http_server.root_module.addImport("nanoapi", mod);

    const run_http_server = b.addRunArtifact(http_server);
    if (b.args) |args| run_http_server.addArgs(args);

    const http_server_step = b.step("http-server", "Run benchmark HTTP server");
    http_server_step.dependOn(&run_http_server.step);
}
