# NanoAPI

NanoAPI is a pure Zig HTTP API framework with FastAPI-inspired ergonomics:
typed route parameters, response helpers, OpenAPI metadata, streaming responses,
middleware, upload helpers, and a small multi-worker native HTTP/1.1 server.

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
chunked streams, server-sent events, and LLM-style token streams.

```zig
fn tokens(ctx: *nano.StreamContext) !void {
    var llm = nano.LLMStreamWriter.init(ctx);
    try llm.token("hel");
    try llm.token("lo");
    try llm.done();
}

fn chat(req: *nano.Request) !nano.Response {
    return nano.LLMStreamResponse.init(req.allocator, tokens, .{});
}

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

## Middleware

Middleware wraps request handling in registration order. Call `ctx.next()` to
continue to the next middleware or route handler, or return a response directly
to short-circuit.

```zig
fn auth(ctx: *nano.MiddlewareContext) !nano.Response {
    if (ctx.req.header("authorization") == null) {
        return nano.JSONResponse.static(ctx.req.allocator, "{\"detail\":\"unauthorized\"}", .{
            .status_code = nano.status.HTTP_401_UNAUTHORIZED,
        });
    }
    var res = try ctx.next();
    errdefer res.deinit();
    try res.setHeader("x-api", "nano");
    return res;
}

try app.addMiddleware(auth);
```

## Forms And Uploads

`Request.formData()` parses `multipart/form-data` and
`application/x-www-form-urlencoded` request bodies. Parsed values are slices into
the request body and remain valid for the current request.

```zig
fn upload(req: *nano.Request) !nano.Response {
    var form = try req.formData();
    defer form.deinit();

    const title = form.field("title") orelse "";
    const file = form.file("file") orelse return nano.response.jsonError(
        req.allocator,
        nano.status.HTTP_422_UNPROCESSABLE_ENTITY,
        "missing file",
        &.{},
    );

    _ = title;
    _ = file.content;
    return nano.JSONResponse.static(req.allocator, "{\"ok\":true}", .{});
}
```

## Serverless

The serverless core adapter is in `nano.serverless`. It turns a platform-neutral
invocation into a normal NanoAPI request, so middleware and routing behave the
same as the native server path.

```zig
var out = try nano.serverless.handleBytes(&app, allocator, nano.ServerlessInvocation.init(
    "GET",
    "/users/42?verbose=true",
    &.{},
    "",
));
defer out.deinit();
```

AWS HTTP API v2 / Lambda Function URL JSON events can use the first platform
adapter:

```zig
const lambda_response_json = try nano.aws_http_v2.handleJson(&app, allocator, event_json);
defer allocator.free(lambda_response_json);
```

The longer adapter and infrastructure plan lives in
[`architecture.md`](architecture.md).

## Server Runtime

The built-in server is a compact HTTP/1.1 implementation with keep-alive. The
default runtime is `.auto`: on macOS and BSD targets it uses the kqueue event
loop; elsewhere it falls back to thread-per-connection until another event
backend is added. The event-loop runtime is multicore by default: worker count
`0` means one listener/loop per logical CPU using `SO_REUSEPORT` where the OS
supports it.

The hot response path avoids unnecessary allocations and omits redundant
`Connection: keep-alive` headers for HTTP/1.1 responses.

```zig
try app.listenAndServe(std.heap.smp_allocator, .{
    .host = .{ 127, 0, 0, 1 },
    .port = 8080,
    .runtime = .auto,
    .worker_threads = 0,
});
```

## Performance

NanoAPI is currently optimized around a small number of hot paths:

- exact `GET /` dispatch avoids the radix router entirely
- exact static routes are cached before falling through to parameterized routing
- parsed request path/query slices are threaded into `Request`
- middleware falls through with one tiny context object around the router
- typed routes skip DHI validation when no validation convention is present
- common `200 application/json` byte responses use a compact contiguous write path for small bodies
- HTTP/1.1 keep-alive responses avoid redundant connection headers
- kqueue event-loop workers can spread accepted connections across cores

Recent local comparison using equivalent JSON handlers:

Environment: macOS arm64, Zig 0.16.0, `wrk 4.2.0`, `-t4 -c64 -d3s`.
NanoAPI used `event_loop` with `worker_threads=0` (auto). The Rust comparison
servers used 4 workers.

| Framework | `/` | `/users/42?verbose=true` | `/auth` | Average | vs NanoAPI |
| --- | ---: | ---: | ---: | ---: | ---: |
| NanoAPI | 148.1k | 149.5k | 149.4k | 149.0k | 1.00x |
| Rust Actix Web | 152.7k | 151.1k | 151.9k | 151.9k | 1.02x |
| Rust xitca-web | 152.6k | 150.5k | 150.6k | 151.3k | 1.02x |
| turboAPI | 146.7k | 146.0k | 127.1k | 139.9k | 0.94x |
| http.zig | 130.8k | 129.5k | 132.7k | 131.0k | 0.88x |
| Go Fiber | 110.9k | 110.3k | 110.9k | 110.7k | 0.74x |
| Go net/http | 99.8k | 96.7k | 92.8k | 96.4k | 0.65x |
| FastAPI + uvicorn | 10.1k | 8.7k | 8.7k | 9.1k | 0.06x |

Higher client concurrency was not better on this localhost profile. With
`wrk -t8 -c128 -d5s`, NanoAPI averaged 134.6k req/s, Actix averaged 130.6k
req/s, and xitca-web averaged 134.8k req/s.

Treat these numbers as directional; they vary by machine, thermal state, Zig
build, and background load.

The next likely performance wins are worker scheduling tuning,
request/response arena reuse, lower-copy writes, better request parser state
reuse, specialized typed query parsers, and stricter benchmark regression
thresholds.

## Build And Bench

```bash
zig build test
zig build -Doptimize=ReleaseFast bench -- 10000000
zig build -Doptimize=ReleaseFast bench -- 1000000 --warmup 100000 --repeat 5 --format=json
zig build -Doptimize=ReleaseFast http-server -- 8080
zig build -Doptimize=ReleaseFast http-server -- 8080 event_loop
zig build -Doptimize=ReleaseFast http-server -- 8080 event_loop 4
```

The dispatch benchmark covers root dispatch, typed path/query dispatch, exact
static route lookup at 64 routes, direct typed path/query parsing, request
header/cookie helpers, typed JSON body parsing, and raw turboapi-core lookup.

Example local `wrk` profile:

```bash
wrk -t4 -c64 -d10s --latency http://127.0.0.1:8080/
wrk -t4 -c64 -d10s --latency 'http://127.0.0.1:8080/users/42?verbose=true'
./scripts/bench-http.sh
WORKERS=4 ./scripts/bench-http.sh
./scripts/check-dispatch-bench.sh
```

## Feature Shape

Done:

- `NanoAPI` and `APIRouter`
- typed path/query structs
- middleware stack
- JSON, text, HTML, redirect, file, stream, and SSE responses
- LLM-style token streaming over SSE
- multipart file uploads and URL-encoded form parsing
- serverless invocation core adapter
- AWS HTTP API v2 serverless adapter
- cookie helpers
- status constants
- security metadata helpers
- OpenAPI 3.1 JSON generation
- DHI-backed typed validation
- native HTTP/1.1 server and dispatch benchmarks

Next:

- Fetch-style serverless adapter
- dependency injection execution
- WebSocket upgrade routes
- optional HTTP/3 and QUIC transport sharing the same app/router layer

## License

MIT
