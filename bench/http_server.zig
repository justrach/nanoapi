const std = @import("std");
const nano = @import("nanoapi");

const PathParams = struct {
    user_id: i64,
};

const QueryParams = struct {
    verbose: bool = false,
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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const port = try portFromArgs(init.minimal.args);

    var app = try nano.NanoAPI.init(allocator, .{ .title = "NanoAPI wrk bench" });
    defer app.deinit();

    try app.get("/", root, .{});
    try app.getTyped(PathParams, QueryParams, "/users/{user_id}", user, .{});

    std.debug.print("nanoapi HTTP benchmark server listening on http://127.0.0.1:{d}\n", .{port});
    try nano.server.serve(&app, allocator, .{ .port = port });
}

fn portFromArgs(args_state: std.process.Args) !u16 {
    var args = std.process.Args.Iterator.init(args_state);
    defer args.deinit();
    _ = args.next();
    const raw = args.next() orelse return 8080;
    return try std.fmt.parseInt(u16, raw, 10);
}
