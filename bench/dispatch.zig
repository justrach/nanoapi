const std = @import("std");
const nano = @import("nanoapi");

const PathParams = struct {
    user_id: i64,
};

const QueryParams = struct {
    verbose: bool = false,
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
    const iterations = try iterationsFromArgs(init.minimal.args);

    var api = try nano.NanoAPI.init(allocator, .{ .title = "Bench" });
    defer api.deinit();

    try api.get("/", staticHandler, .{});
    try nano.typed.get(&api, PathParams, QueryParams, "/users/{user_id}", typedUser, .{});

    var static_req = nano.Request.init(allocator, "GET", "/", &.{}, "");
    var typed_req = nano.Request.init(allocator, "GET", "/users/42?verbose=true", &.{}, "");

    try benchRoute(init.io, "nano dispatch static", &api, &static_req, iterations);
    try benchRoute(init.io, "nano dispatch typed param+query", &api, &typed_req, iterations);
    try benchCoreRouter(init.io, allocator, iterations);
}

fn benchRoute(io: std.Io, name: []const u8, api: *nano.NanoAPI, req: *nano.Request, iterations: u64) !void {
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io);

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var res = try api.handle(req);
        checksum +%= res.status_code + res.body.len;
        res.deinit();
    }

    const elapsed_ns = elapsedNs(start, io);
    printResult(name, iterations, elapsed_ns, checksum);
}

fn benchCoreRouter(io: std.Io, allocator: std.mem.Allocator, iterations: u64) !void {
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
    printResult("turboapi-core route lookup", iterations, elapsed_ns, checksum);
}

fn elapsedNs(start: std.Io.Timestamp, io: std.Io) u64 {
    const end = std.Io.Clock.awake.now(io);
    return @intCast(start.durationTo(end).toNanoseconds());
}

fn printResult(name: []const u8, iterations: u64, elapsed_ns: u64, checksum: u64) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const ops = @as(f64, @floatFromInt(iterations)) / seconds;
    const ns_per = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    std.debug.print("{s}: {d} ops in {d:.3}s = {d:.2} ops/s, {d:.2} ns/op (checksum={d})\n", .{
        name,
        iterations,
        seconds,
        ops,
        ns_per,
        checksum,
    });
}

fn iterationsFromArgs(args_state: std.process.Args) !u64 {
    var args = std.process.Args.Iterator.init(args_state);
    defer args.deinit();
    _ = args.next();
    const raw = args.next() orelse return 1_000_000;
    return try std.fmt.parseInt(u64, raw, 10);
}
