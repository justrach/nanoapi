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
loop, on Linux it uses io_uring (kernel 5.1+, multishot accept on 5.19+),
and elsewhere it falls back to thread-per-connection. All event runtimes are
multicore by default: worker count `0` means one listener/loop per logical
CPU using `SO_REUSEPORT` where the OS supports it. The io_uring submission
queue depth is controlled by `Options.io_uring_entries` (default 1024).

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
- pre-rendered static-response cache emits the full HTTP bytes via `memcpy` on a hit (skips handler dispatch, `Content-Length` formatting, and the `Response` struct entirely)
- parsed request path/query slices are threaded into `Request`
- middleware falls through with one tiny context object around the router
- typed routes skip DHI validation when no validation convention is present
- common `200 application/json` byte responses use a compact contiguous write path for small bodies
- HTTP/1.1 keep-alive responses avoid redundant connection headers
- kqueue and io_uring runtimes both spread accepted connections across cores via `SO_REUSEPORT`
- io_uring runtime coalesces pipelined fast-JSON responses into a single `send()` per worker wakeup

### macOS event_loop (kqueue)

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

### Linux io_uring (kernel 6.18.5, ARM64, Apple `container`, 8 vCPU)

Environment: each server in its own Apple [`container`](https://github.com/apple/container)
lightweight VM (kernel 6.18.5, ARM64), 8 vCPU, 4 workers, `wrk 4.2.0`
running inside the same container against `127.0.0.1` so the wire is
in-VM kernel loopback (no virtio-net, no host bridge). nanoapi used
`runtime=auto` — `effectiveRuntime` resolves to `io_uring` on Linux.
Reproducer (Containerfile + lua scripts + Fiber/actix sources) lives in
[`bench/linux/`](bench/linux/).

Throughput (req/s):

| benchmark                       | nanoapi io_uring | Go Fiber 2.52  | actix-web 4.9  | vs Fiber  | vs actix  |
|---------------------------------|-----------------:|---------------:|---------------:|----------:|----------:|
| GET / 1 conn (RTT-bound)        |       **32,283** |         27,414 |         27,778 |     1.18× |     1.16× |
| GET / 256 conns                 |      **983,919** |        709,263 |        406,618 |     1.39× |     2.42× |
| GET / pipelined 16× (64 conns)  |    **7,955,340** |      1,607,724 |        563,404 |     4.95× |    14.12× |
| POST /users (typed body, 64c)   |      **885,577** |        471,977 |        134,345 |     1.88× |     6.59× |
| GET /auth (header lookups, 64c) |      **959,798** |        621,267 |        315,968 |     1.54× |     3.04× |

p50 / p99 latency:

| benchmark                       | nanoapi io_uring | Go Fiber          | actix-web         |
|---------------------------------|------------------|-------------------|-------------------|
| GET / 1 conn                    | 32 µs / 39 µs    | 36 µs / 59 µs     | 35 µs / 48 µs     |
| GET / 256 conns                 | 129 µs / 314 µs  | 316 µs / 125 ms ‡ | 522 µs / 1.46 ms  |
| GET / pipelined 16×             | 52 µs / —        | 401 µs / 1.90 ms  | 1.28 ms / —       |
| POST /users                     | 61 µs / 116 µs   | 117 µs / 582 µs   | 456 µs / 940 µs   |
| GET /auth                       | 56 µs / 100 µs   | 86 µs / 370 µs    | 142 µs / 533 µs   |

‡ Fiber's 256-conn p99 spikes into the 100 ms range under fasthttp's
goroutine-per-connection contention at this fan-out.

The macOS table is included mainly to show how the runtime ordering
inverts once the io_uring path, multishot accept, and pre-rendered static
cache come into play on Linux. On the macOS table actix narrowly led at
1.02×; on Linux io_uring nanoapi leads on every benchmark, by **1.16× to
14.12×**.

Treat all numbers as directional; they vary by machine, thermal state,
Zig build, kernel version, and background load.

### Performance roadmap

Concrete, ordered next steps for the io_uring runtime, synthesized from a
deep-dive of `src/io_uring.zig` and a survey of state-of-the-art io_uring
HTTP servers (monoio, glommio, compio, Apache Iggy, liburing examples,
Jens Axboe's 2023–2025 talks). Numbers are gains reported by other
projects on similar workloads, not predictions for this codebase.

1. **`IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_SINGLE_ISSUER`** — one
   flag flip in `IoConn.run`'s `linux.IoUring.init`. Each worker already
   submits from one thread, so both flags are safe. Defers task_work to
   the next `io_uring_enter` and skips internal locking. Reported gain:
   single-digit % across recv-heavy loops; effectively free.
2. **Multishot recv + provided buffer rings (`IORING_REGISTER_PBUF_RING`)**
   — biggest structural change. Replace the per-`IoConn` recv buffer
   and the always-fresh `submitRecv` / `onRecv` cycle with a single
   per-worker buffer ring (e.g. 4096 × 2 KiB) and one armed multishot
   recv per connection. Removes the per-connection recv-buf RSS and one
   SQE per byte arrival. Reported gain: 6–15 % on recv-heavy paths.
3. **`IORING_RECVSEND_POLL_FIRST` + `IORING_CQE_F_SOCK_NONEMPTY`** —
   on the recv→send→recv state machine, set `POLL_FIRST` after a send
   and skip it when the prior CQE flagged `F_SOCK_NONEMPTY`. Cheap;
   the recent DBMS study (arXiv 2512.04859) reports cutting wait-path
   CPU "up to 1.5×".
4. **Multishot accept-direct + fixed file table
   (`IORING_REGISTER_FILES_SPARSE` + `IOSQE_FIXED_FILE`)** — accepted
   sockets land directly in a registered FD table; every recv/send
   skips fdget/fdput. Reported gain: ~5–10 % on small-IO loops.
5. **Send bundles (`IORING_RECVSEND_BUNDLE`, kernel 6.10+)** — drain
   N pre-rendered static responses from a buffer ring with one SQE.
   Pairs with the existing static-response cache; helps the pipelined
   GET / column once SQE submission is the bottleneck.
6. **Fix `staticPlaceholderHandler` (`src/routing.zig:412`)** — the
   doc comment promises behaviour parity with the static-dispatch
   shortcut, but the body returns HTTP 500. Re-emit the cached body
   instead. Correctness, not perf, but it blocks running the bench
   harness with middleware enabled.
7. **Eliminate the synchronous `linux.write()` fallback** — non-fast-path
   responses (file, stream, custom headers) currently block the worker
   for the entire response. Route `.bytes`-with-custom-headers through
   the existing send pump; for `.file`, queue `IORING_OP_SPLICE` /
   `IORING_OP_SENDFILE`; for `.stream`, render chunked frames into
   `write_buf`. Removes a single-slow-client foot-gun on mixed workloads.
8. **Body-aware recv minlen for typed POST** — pair multishot recv with
   `MSG_WAITALL`-equivalent so the kernel waits until the full
   `Content-Length` is in the buffer before posting a CQE. Directly
   attacks the gap between POST /users (886 k) and GET / (~1 M
   non-pipelined).
9. **Hash-based static dispatch** — replace the length-bounded
   `std.mem.eql` walk in `tryStaticDispatch` (`src/routing.zig:218`)
   with `(method_slot, xxhash3(path))` keyed lookup. Reported 2–5 %
   on the hottest static GET path.

Things deliberately *not* on the list: `IORING_SETUP_SQPOLL` (burns a
core, inverts the thread-per-core model), zero-copy send (`SEND_ZC`
notification overhead exceeds the win for sub-1 KiB bodies), io_uring
zero-copy receive (HTTP/1 doesn't benefit from header/payload split),
and AF_XDP / XDP (would require a userspace TCP stack).

References:
[io_uring and networking in 2023](https://github.com/axboe/liburing/wiki/io_uring-and-networking-in-2023) ·
[multishot recv (LWN 899498)](https://lwn.net/Articles/899498/) ·
[defer task work (LWN 906470)](https://lwn.net/Articles/906470/) ·
[descriptorless / fixed files (LWN 863071)](https://lwn.net/Articles/863071/) ·
[Apache Iggy thread-per-core io_uring migration](https://iggy.apache.org/blogs/2026/02/27/thread-per-core-io_uring/) ·
[io_uring for High-Performance DBMSs (arXiv:2512.04859)](https://arxiv.org/html/2512.04859v1).

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

For the Linux io_uring suite that produced the cross-framework numbers
above (cross-compiles a static `aarch64-linux-musl` binary, runs it inside
an Apple [`container`](https://github.com/apple/container) / `docker` /
`podman` VM with `wrk` against in-VM kernel loopback, and prints the same
five wrk results):

```bash
./bench/linux/run.sh
RUNTIME=docker CPUS=8 WORKERS=4 DURATION=15s ./bench/linux/run.sh
```

The Go Fiber and actix-web servers used in the cross-framework comparison
ship under `bench/linux/comparison/`; see `bench/linux/README.md` for the
exact build commands.

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
