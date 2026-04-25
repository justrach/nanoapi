const std = @import("std");
const nano = @import("nanoapi");

const PathParams = struct {
    user_id: i64,
};

const QueryParams = struct {
    verbose: bool = false,
};

const OutputFormat = enum {
    text,
    json,
};

const Config = struct {
    iterations: u64 = 1_000_000,
    warmup: u64 = 0,
    repeat: u32 = 1,
    format: OutputFormat = .text,
};

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    elapsed_ns: u64,
    checksum: u64,
};

const BenchSummary = struct {
    name: []const u8,
    iterations: u64,
    repeat: u32,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    total_ns: u128 = 0,
    checksum: u64 = 0,

    fn add(self: *BenchSummary, result: BenchResult) void {
        self.min_ns = @min(self.min_ns, result.elapsed_ns);
        self.max_ns = @max(self.max_ns, result.elapsed_ns);
        self.total_ns += result.elapsed_ns;
        self.checksum +%= result.checksum;
    }
};

fn typedUser(ctx: nano.typed.Context(PathParams, QueryParams)) anyerror!nano.Response {
    const body = try std.fmt.allocPrint(
        ctx.raw.allocator,
        "{{\"user_id\":{d},\"verbose\":{s}}}",
        .{ ctx.path.user_id, if (ctx.query.verbose) "true" else "false" },
    );
    return nano.Response.fromOwnedBody(ctx.raw.allocator, body, .{ .media_type = "application/json" });
}

fn staticHandler(req: *nano.Request) anyerror!nano.Response {
    return nano.JSONResponse.init(req.allocator, "{\"ok\":true}", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const config = try configFromArgs(init.minimal.args);

    var api = try nano.NanoAPI.init(allocator, .{ .title = "Bench" });
    defer api.deinit();

    try api.get("/", staticHandler, .{});
    try nano.typed.get(&api, PathParams, QueryParams, "/users/{user_id}", typedUser, .{});

    var static_req = nano.Request.init(allocator, "GET", "/", &.{}, "");
    var typed_req = nano.Request.init(allocator, "GET", "/users/42?verbose=true", &.{}, "");

    if (config.warmup > 0) {
        _ = try benchRoute(init.io, "nano dispatch static", &api, &static_req, config.warmup);
        _ = try benchRoute(init.io, "nano dispatch typed param+query", &api, &typed_req, config.warmup);
        _ = try benchCoreRouter(init.io, allocator, config.warmup);
    }

    var summaries = [_]BenchSummary{
        .{ .name = "nano dispatch static", .iterations = config.iterations, .repeat = config.repeat },
        .{ .name = "nano dispatch typed param+query", .iterations = config.iterations, .repeat = config.repeat },
        .{ .name = "turboapi-core route lookup", .iterations = config.iterations, .repeat = config.repeat },
    };

    for (0..config.repeat) |_| {
        summaries[0].add(try benchRoute(init.io, summaries[0].name, &api, &static_req, config.iterations));
        summaries[1].add(try benchRoute(init.io, summaries[1].name, &api, &typed_req, config.iterations));
        summaries[2].add(try benchCoreRouter(init.io, allocator, config.iterations));
    }

    printSummaries(&summaries, config.format);
}

fn benchRoute(io: std.Io, name: []const u8, api: *nano.NanoAPI, req: *nano.Request, iterations: u64) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io);

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var res = try api.handle(req);
        checksum +%= res.status_code + res.body.len;
        res.deinit();
    }

    const elapsed_ns = elapsedNs(start, io);
    return .{
        .name = name,
        .iterations = iterations,
        .elapsed_ns = elapsed_ns,
        .checksum = checksum,
    };
}

fn benchCoreRouter(io: std.Io, allocator: std.mem.Allocator, iterations: u64) !BenchResult {
    var router = nano.core.Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users/{user_id}", "handler");

    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io);

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var matched = router.findRoute("GET", "/users/42").?;
        checksum +%= matched.handler_key.len;
        checksum +%= @intCast(matched.params.getInt("user_id") orelse 0);
        matched.deinit();
    }

    const elapsed_ns = elapsedNs(start, io);
    return .{
        .name = "turboapi-core route lookup",
        .iterations = iterations,
        .elapsed_ns = elapsed_ns,
        .checksum = checksum,
    };
}

fn elapsedNs(start: std.Io.Timestamp, io: std.Io) u64 {
    const end = std.Io.Clock.awake.now(io);
    return @intCast(start.durationTo(end).toNanoseconds());
}

fn printSummaries(summaries: []const BenchSummary, format: OutputFormat) void {
    switch (format) {
        .text => {
            for (summaries) |summary| {
                if (summary.repeat == 1) {
                    printResult(summary.name, summary.iterations, summary.min_ns, summary.checksum);
                } else {
                    printRepeatedResult(summary);
                }
            }
        },
        .json => printJsonSummaries(summaries),
    }
}

fn printResult(name: []const u8, iterations: u64, elapsed_ns: u64, checksum: u64) void {
    const seconds = secondsFromNs(elapsed_ns);
    const ops = @as(f64, @floatFromInt(iterations)) / seconds;
    const ns_per = nsPerOp(elapsed_ns, iterations);
    std.debug.print("{s}: {d} ops in {d:.3}s = {d:.2} ops/s, {d:.2} ns/op (checksum={d})\n", .{
        name, iterations, seconds, ops, ns_per, checksum,
    });
}

fn printRepeatedResult(summary: BenchSummary) void {
    const avg_ns = @as(f64, @floatFromInt(summary.total_ns)) / @as(f64, @floatFromInt(summary.repeat));
    std.debug.print(
        "{s}: {d} ops x {d} repeats, min {d:.2} ns/op, avg {d:.2} ns/op, max {d:.2} ns/op (checksum={d})\n",
        .{
            summary.name,
            summary.iterations,
            summary.repeat,
            nsPerOp(summary.min_ns, summary.iterations),
            avg_ns / @as(f64, @floatFromInt(summary.iterations)),
            nsPerOp(summary.max_ns, summary.iterations),
            summary.checksum,
        },
    );
}

fn printJsonSummaries(summaries: []const BenchSummary) void {
    std.debug.print("[\n", .{});
    for (summaries, 0..) |summary, i| {
        const avg_ns = @as(f64, @floatFromInt(summary.total_ns)) / @as(f64, @floatFromInt(summary.repeat));
        std.debug.print(
            "  {{\"name\":\"{s}\",\"iterations\":{d},\"repeat\":{d},\"min_ns_per_op\":{d:.3},\"avg_ns_per_op\":{d:.3},\"max_ns_per_op\":{d:.3},\"checksum\":{d}}}{s}\n",
            .{
                summary.name,
                summary.iterations,
                summary.repeat,
                nsPerOp(summary.min_ns, summary.iterations),
                avg_ns / @as(f64, @floatFromInt(summary.iterations)),
                nsPerOp(summary.max_ns, summary.iterations),
                summary.checksum,
                if (i + 1 == summaries.len) "" else ",",
            },
        );
    }
    std.debug.print("]\n", .{});
}

fn secondsFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
}

fn nsPerOp(ns: u64, iterations: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations));
}

fn configFromArgs(args_state: std.process.Args) !Config {
    var args = std.process.Args.Iterator.init(args_state);
    defer args.deinit();
    _ = args.next();

    var config: Config = .{};
    var saw_iterations = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--format=json")) {
            config.format = .json;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            const raw = args.next() orelse return error.MissingArgument;
            config.warmup = try std.fmt.parseInt(u64, raw, 10);
        } else if (std.mem.eql(u8, arg, "--repeat")) {
            const raw = args.next() orelse return error.MissingArgument;
            config.repeat = try std.fmt.parseInt(u32, raw, 10);
            if (config.repeat == 0) return error.InvalidRepeat;
        } else if (!saw_iterations) {
            config.iterations = try std.fmt.parseInt(u64, arg, 10);
            saw_iterations = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return config;
}
