const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("turboapi_core", .{
        .target = target,
        .optimize = optimize,
    });
    const core_mod = core_dep.module("turboapi-core");
    const dhi_dep = b.dependency("dhi", .{
        .target = target,
        .optimize = optimize,
    });
    const dhi_mod = dhi_dep.module("dhi");
    const dhi_model_mod = dhi_dep.module("model");

    const mod = b.addModule("nanoapi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("turboapi-core", core_mod);
    mod.addImport("dhi", dhi_mod);
    mod.addImport("dhi-model", dhi_model_mod);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addImport("turboapi-core", core_mod);
    tests.root_module.addImport("dhi", dhi_mod);
    tests.root_module.addImport("dhi-model", dhi_model_mod);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const bench_iterations = b.option(u64, "bench-iterations", "Dispatch benchmark iterations");
    const bench_warmup = b.option(u64, "bench-warmup", "Dispatch benchmark warmup iterations");
    const bench_repeat = b.option(u32, "bench-repeat", "Dispatch benchmark repetitions");
    const bench_json = b.option(bool, "bench-json", "Emit dispatch benchmark results as JSON") orelse false;

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
    if (bench_iterations) |iterations| run_bench.addArg(b.fmt("{d}", .{iterations}));
    if (bench_warmup) |warmup| {
        run_bench.addArg("--warmup");
        run_bench.addArg(b.fmt("{d}", .{warmup}));
    }
    if (bench_repeat) |repeat| {
        run_bench.addArg("--repeat");
        run_bench.addArg(b.fmt("{d}", .{repeat}));
    }
    if (bench_json) run_bench.addArg("--format=json");
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
    const http_server_step = b.step("http-server", "Run benchmark HTTP server");
    http_server_step.dependOn(&run_http_server.step);
}
