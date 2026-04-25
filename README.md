# NanoAPI

NanoAPI is a pure Zig HTTP API framework with FastAPI-inspired ergonomics:
typed route parameters, response helpers, OpenAPI metadata, streaming responses,
and a small native HTTP/1.1 server.

The hot routing path is backed by `turboapi-core`, while validation primitives
come from `dhi`. The current dependency pin uses the `dhi` performance branch
from `justrach/dhi#54`; switch it back to `dhi` main once that PR lands.

## Install

For local development, clone the repo and run the standard Zig build steps:

```bash
git clone https://github.com/justrach/nanoapi.git
cd nanoapi
zig build test
```

To consume NanoAPI from another Zig package, add it as a dependency and import
the `nanoapi` module from your `build.zig`:

```zig
const nano_dep = b.dependency("nanoapi", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("nanoapi", nano_dep.module("nanoapi"));
```

## Quick Start

```zig
const std = @import("std");
const nano = @import("nanoapi");

fn root(req: *nano.Request) !nano.Response {
    return nano.JSONResponse.static(req.allocator, "{\"ok\":true}", .{});
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var app = try nano.NanoAPI.init(allocator, .{
        .title = "Example API",
        .version = "1.0.0",
    });
    defer app.deinit();

    try app.get("/", root, .{ .tags = &.{"health"} });

    try app.listenAndServe(allocator, .{
        .host = .{ 127, 0, 0, 1 },
        .port = 8080,
    });
}
```

## Typed Routes

Route handlers can parse path and query values into Zig structs. Defaults and
optional fields work naturally, and DHI-backed validation runs only when a struct
uses validation naming conventions such as `email`, `*_email`, or `*_ne`.

```zig
const PathParams = struct {
    user_id: i64,
};

const QueryParams = struct {
    verbose: bool = false,
};

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

## Responses

NanoAPI includes response helpers for JSON, text, HTML, redirects, file bodies,
chunked streams, and server-sent events.

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

## Server Runtime

The built-in server is a compact HTTP/1.1 implementation with keep-alive. The
default runtime is `.auto`: on macOS and BSD targets it uses the kqueue event
loop; elsewhere it falls back to thread-per-connection until another event
backend is added.

The hot response path avoids unnecessary allocations and omits redundant
`Connection: keep-alive` headers for HTTP/1.1 responses.

```zig
try app.listenAndServe(std.heap.smp_allocator, .{
    .host = .{ 127, 0, 0, 1 },
    .port = 8080,
    .runtime = .auto,
});
```

## Performance

NanoAPI is currently optimized around a small number of hot paths:

- exact `GET /` dispatch avoids the radix router entirely
- exact static routes are cached before falling through to parameterized routing
- parsed request path/query slices are threaded into `Request`
- typed routes skip DHI validation when no validation convention is present
- common `200 application/json` byte responses use a compact fast write path
- HTTP/1.1 keep-alive responses avoid redundant connection headers

Recent local comparison against `karlseguin/http.zig` using equivalent handlers:

| Route | NanoAPI | http.zig |
| --- | ---: | ---: |
| `/` | ~168k req/s | ~166k req/s |
| `/users/42?verbose=true` | ~167k req/s | ~166k req/s |

Treat these numbers as directional; they vary by machine, thermal state, Zig
build, and background load.

The next likely performance wins are request/response arena reuse, vectorized or
lower-copy writes, better request parser state reuse, specialized typed query
parsers, and a reproducible benchmark suite with regression thresholds.

## Build And Bench

```bash
zig build test
zig build -Doptimize=ReleaseFast bench -- 10000000
zig build -Doptimize=ReleaseFast http-server -- 8080
```

Example local `wrk` profile:

```bash
wrk -t4 -c64 -d10s --latency http://127.0.0.1:8080/
wrk -t4 -c64 -d10s --latency 'http://127.0.0.1:8080/users/42?verbose=true'
```

## Feature Shape

Done:

- `NanoAPI` and `APIRouter`
- typed path/query structs
- JSON, text, HTML, redirect, file, stream, and SSE responses
- cookie helpers
- status constants
- security metadata helpers
- OpenAPI 3.1 JSON generation
- DHI-backed typed validation
- native HTTP/1.1 server and dispatch benchmarks

Next:

- middleware stack
- dependency injection execution
- file uploads and form parsing
- WebSocket upgrade routes
- optional HTTP/3 and QUIC transport sharing the same app/router layer

## License

MIT
