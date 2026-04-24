# NanoAPI

NanoAPI is a pure Zig HTTP API library with FastAPI-style behavior as a parity
target. It reuses
`turboapi-core` for the hot router and HTTP helpers, then layers a Zig API over
it with familiar names like `NanoAPI`, `APIRouter`, `Request`, `Response`,
`JSONResponse`, `HTTPException`, `Query`, `Path`, and `status`.

This is the first implementation slice: route registration, route inclusion,
typed path/query parsing, response helpers, security scheme metadata, background
tasks, and OpenAPI 3.1 JSON generation.

## Example

```zig
const std = @import("std");
const nano = @import("nanoapi");

fn getUser(req: *nano.Request) !nano.Response {
    const user_id = req.pathInt("user_id") orelse 0;
    const body = try std.fmt.allocPrint(
        req.allocator,
        "{{\"user_id\":{d}}}",
        .{user_id},
    );
    return nano.Response.fromOwnedBody(req.allocator, body, .{
        .media_type = "application/json",
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var app = try nano.NanoAPI.init(allocator, .{
        .title = "Example",
        .version = "1.0.0",
    });
    defer app.deinit();

    const parameters = [_]nano.Parameter{
        nano.Path("user_id", .integer, .{}),
        nano.Query("verbose", .boolean, .{ .required = false }),
    };

    try app.get("/users/{user_id}", getUser, .{
        .tags = &.{"users"},
        .parameters = &parameters,
    });
}
```

## Type-Safe Routes

```zig
const PathParams = struct { user_id: i64 };
const QueryParams = struct { verbose: bool = false };

fn getUser(ctx: nano.typed.Context(PathParams, QueryParams)) !nano.Response {
    const body = try std.fmt.allocPrint(
        ctx.raw.allocator,
        "{{\"user_id\":{d},\"verbose\":{s}}}",
        .{ ctx.path.user_id, if (ctx.query.verbose) "true" else "false" },
    );
    return nano.Response.fromOwnedBody(ctx.raw.allocator, body, .{
        .media_type = "application/json",
    });
}

try app.getTyped(PathParams, QueryParams, "/users/{user_id}", getUser, .{});
```

## Build

```bash
zig build test
zig build -Doptimize=ReleaseFast bench -- 10000000
zig build -Doptimize=ReleaseFast http-server -- 8080
```

The package depends on `turboapi_core`, pinned in `build.zig.zon`.
It also depends on `dhi` for Zig-native validation primitives and model-style
descriptors.

## HTTP Server

```zig
try app.listenAndServe(std.heap.smp_allocator, .{
    .host = .{ 127, 0, 0, 1 },
    .port = 8080,
});
```

The initial server is a compact HTTP/1.1 implementation with keep-alive and a
thread per accepted connection. It is enough for local `wrk` benchmarking while
the runtime evolves.

## Streaming, Files, and SSE

Responses now keep the fast byte-body path while also supporting streamed files
and chunked stream writers:

```zig
fn events(ctx: *nano.StreamContext) !void {
    var sse = nano.SseWriter.init(ctx);
    try sse.event("ready", "hello", "1");
}

fn sse(req: *nano.Request) !nano.Response {
    return nano.EventSourceResponse.init(req.allocator, events, .{});
}

fn download(req: *nano.Request) !nano.Response {
    return nano.FileResponse.init(req.allocator, "assets/report.pdf", null, .{});
}
```

WebSockets should be a separate upgrade route that takes over the accepted
connection instead of returning a normal `Response`. QUIC/HTTP3 should be a
separate transport backend sharing `NanoAPI.handle`; it is not a small patch to
the HTTP/1.1 TCP loop.

## FastAPI Parity Roadmap

- Done: routing decorators as Zig methods, routers with prefixes, typed
  path/query structs, response classes, cookies, status constants, basic
  security helpers, OpenAPI, dispatch benchmark, native HTTP server loop,
  streamed files, chunked streaming responses, SSE helpers, DHI-backed typed
  validation.
- Next: dependency injection execution, middleware stack, file uploads/forms,
  WebSocket upgrade routes, optional HTTP3/QUIC transport.

## License

MIT
