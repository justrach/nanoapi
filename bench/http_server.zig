const std = @import("std");
const nano = @import("nanoapi");

const PathParams = struct {
    user_id: i64,
};

const QueryParams = struct {
    verbose: bool = false,
};

const Config = struct {
    port: u16 = 8080,
    runtime: nano.server.Runtime = .auto,
    check_only: bool = false,
};

fn root(req: *nano.Request) anyerror!nano.Response {
    return nano.JSONResponse.static(req.allocator, "{\"ok\":true}", .{});
}

fn user(ctx: nano.typed.Context(PathParams, QueryParams)) anyerror!nano.Response {
    const body = try std.fmt.allocPrint(
        ctx.raw.allocator,
        "{{\"user_id\":{d},\"verbose\":{s}}}",
        .{ ctx.path.user_id, if (ctx.query.verbose) "true" else "false" },
    );
    return nano.Response.fromOwnedBody(ctx.raw.allocator, body, .{ .media_type = "application/json" });
}

fn auth(req: *nano.Request) anyerror!nano.Response {
    const bearer = req.header("authorization") orelse "";
    const session = req.cookie("session") orelse "";
    if (bearer.len == 0 or session.len == 0) {
        return nano.JSONResponse.static(req.allocator, "{\"authorized\":false}", .{});
    }
    return nano.JSONResponse.static(req.allocator, "{\"authorized\":true}", .{});
}

fn events(ctx: *nano.StreamContext) anyerror!void {
    var writer = nano.SseWriter.init(ctx);
    try writer.event("ready", "1", "1");
}

fn eventStream(req: *nano.Request) anyerror!nano.Response {
    return nano.EventSourceResponse.init(req.allocator, events, .{});
}

fn file(req: *nano.Request) anyerror!nano.Response {
    return nano.FileResponse.init(req.allocator, "README.md", null, .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const config = try configFromArgs(init.minimal.args);

    var app = try nano.NanoAPI.init(allocator, .{ .title = "NanoAPI wrk bench" });
    defer app.deinit();

    try app.get("/", root, .{});
    try app.getTyped(PathParams, QueryParams, "/users/{user_id}", user, .{});
    try app.get("/auth", auth, .{});
    try app.get("/events", eventStream, .{});
    try app.get("/file", file, .{});

    if (config.check_only) return;

    std.debug.print(
        "nanoapi HTTP benchmark server listening on http://127.0.0.1:{d} runtime={t}\n",
        .{ config.port, config.runtime },
    );
    try nano.server.serve(&app, allocator, .{ .port = config.port, .runtime = config.runtime });
}

fn configFromArgs(args_state: std.process.Args) !Config {
    var args = std.process.Args.Iterator.init(args_state);
    defer args.deinit();
    _ = args.next();

    var config: Config = .{};
    var saw_port = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            config.check_only = true;
        } else if (!saw_port) {
            config.port = try std.fmt.parseInt(u16, arg, 10);
            saw_port = true;
        } else {
            config.runtime = try parseRuntime(arg);
        }
    }
    return config;
}

fn parseRuntime(raw: []const u8) !nano.server.Runtime {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "event_loop")) return .event_loop;
    if (std.mem.eql(u8, raw, "thread_per_connection")) return .thread_per_connection;
    return error.InvalidRuntime;
}
