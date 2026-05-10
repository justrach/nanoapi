const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const app_mod = @import("app.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const status = @import("status.zig");

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
extern "c" fn close(fd: c.fd_t) c_int;

pub const Options = struct {
    host: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 8080,
    backlog: c_uint = 2048,
    read_buffer_size: usize = 16 * 1024,
    /// Per-connection batch buffer used to coalesce pipelined keep-alive responses
    /// into a single send() syscall. Larger values batch more requests at the cost
    /// of resident memory per connection.
    write_buffer_size: usize = 16 * 1024,
    max_headers: usize = 64,
    runtime: Runtime = .auto,
    /// Number of event-loop / io_uring workers. 0 means one worker per logical CPU.
    worker_threads: usize = 0,
    /// io_uring submission/completion queue depth (Linux io_uring runtime only).
    io_uring_entries: u16 = 1024,
};

pub const Runtime = enum {
    auto,
    event_loop,
    thread_per_connection,
    /// Linux io_uring runtime. Falls back to event_loop on non-Linux when selected
    /// explicitly; .auto picks io_uring on Linux automatically.
    io_uring,
};

/// Function the runtime calls to dispatch a parsed request to user code.
/// `ctx` is the opaque pointer the dispatcher was registered with.
pub const HandleFn = *const fn (ctx: *anyopaque, req: *request.Request) anyerror!response.Response;

/// Optional fast path: returns pre-rendered HTTP response bytes for a static
/// route, or null to fall back to the normal `handle()` call. Set to null on
/// the dispatcher to disable the static-cache shortcut.
pub const TryStaticDispatchFn = *const fn (ctx: *anyopaque, method: []const u8, path: []const u8) ?[]const u8;

/// Returns true if the dispatcher has middleware registered. The runtime skips
/// the static-cache shortcut when middleware is present so middlewares can run.
pub const HasMiddlewareFn = *const fn (ctx: *anyopaque) bool;

/// Vtable plugged into the runtime so non-`App` consumers (turboAPI's Python
/// FFI dispatch, merjs' SSR dispatch) can drive the same accept loop, parser,
/// and response writer that `App` uses internally.
pub const Dispatcher = struct {
    ctx: *anyopaque,
    handle: HandleFn,
    has_middleware: HasMiddlewareFn,
    try_static_dispatch: ?TryStaticDispatchFn = null,
};

pub const Server = struct {
    dispatcher: Dispatcher,
    allocator: std.mem.Allocator,
    options: Options,
    listen_fd: c.fd_t = -1,

    pub fn init(dispatcher: Dispatcher, allocator: std.mem.Allocator, options: Options) Server {
        return .{
            .dispatcher = dispatcher,
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.listen_fd >= 0) {
            _ = close(self.listen_fd);
            self.listen_fd = -1;
        }
    }

    pub fn listenAndServe(self: *Server) !void {
        const selected = effectiveRuntime(self.options.runtime);
        switch (selected) {
            .io_uring => return self.listenAndServeIoUring(),
            .event_loop => return self.listenAndServeEventLoop(),
            .thread_per_connection => return self.listenAndServeThreaded(),
            .auto => unreachable,
        }
    }

    fn listenAndServeIoUring(self: *Server) !void {
        if (comptime builtin.os.tag != .linux) return error.IoUringNotSupported;
        const worker_count = effectiveWorkerCount(self.options.worker_threads);
        if (worker_count > 1) return self.listenAndServeIoUringWorkers(worker_count);

        self.listen_fd = try createListenSocket(self.options, false);
        return @import("io_uring.zig").run(self, self.listen_fd);
    }

    fn listenAndServeIoUringWorkers(self: *Server, worker_count: usize) !void {
        if (comptime builtin.os.tag != .linux) return error.IoUringNotSupported;
        var worker_index: usize = 1;
        while (worker_index < worker_count) : (worker_index += 1) {
            const thread = try std.Thread.spawn(.{}, ioUringWorker, .{ self, worker_index });
            thread.detach();
        }
        const listen_fd = try createListenSocket(self.options, true);
        defer _ = close(listen_fd);
        try @import("io_uring.zig").run(self, listen_fd);
    }

    fn listenAndServeThreaded(self: *Server) !void {
        self.listen_fd = try createListenSocket(self.options, false);

        while (true) {
            const fd = c.accept(self.listen_fd, null, null);
            switch (c.errno(fd)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |err| return errnoError(err),
            }
            const client_fd: c.fd_t = @intCast(fd);
            configureAcceptedSocket(client_fd);

            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, client_fd }) catch {
                _ = close(client_fd);
                continue;
            };
            thread.detach();
        }
    }

    fn listenAndServeEventLoop(self: *Server) !void {
        const worker_count = effectiveWorkerCount(self.options.worker_threads);
        if (worker_count > 1) return self.listenAndServeEventLoopWorkers(worker_count);

        self.listen_fd = try createListenSocket(self.options, false);
        return self.runEventLoop(self.listen_fd);
    }

    fn listenAndServeEventLoopWorkers(self: *Server, worker_count: usize) !void {
        var worker_index: usize = 1;
        while (worker_index < worker_count) : (worker_index += 1) {
            const thread = try std.Thread.spawn(.{}, eventLoopWorker, .{ self, worker_index });
            thread.detach();
        }

        const listen_fd = try createListenSocket(self.options, true);
        defer _ = close(listen_fd);
        try self.runEventLoop(listen_fd);
    }

    fn runEventLoop(self: *Server, listen_fd: c.fd_t) !void {
        if (comptime !supportsKqueue()) return error.KqueueNotSupported;
        const kq = c.kqueue();
        switch (c.errno(kq)) {
            .SUCCESS => {},
            else => |err| return errnoError(err),
        }
        defer _ = close(kq);

        try registerRead(kq, listen_fd, 0);

        var events: [1024]c.Kevent = undefined;
        while (true) {
            const n = c.kevent(kq, @as([*]const c.Kevent, @ptrCast(&events)), 0, &events, events.len, null);
            switch (c.errno(n)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |err| return errnoError(err),
            }

            for (events[0..@intCast(n)]) |ev| {
                if (ev.ident == @as(usize, @intCast(listen_fd))) {
                    const fd = c.accept(listen_fd, null, null);
                    switch (c.errno(fd)) {
                        .SUCCESS => {},
                        .INTR, .AGAIN => continue,
                        else => continue,
                    }

                    const client_fd: c.fd_t = @intCast(fd);
                    configureAcceptedSocket(client_fd);

                    const conn = Connection.create(self, client_fd) catch {
                        _ = close(client_fd);
                        continue;
                    };
                    registerRead(kq, client_fd, @intFromPtr(conn)) catch {
                        conn.deinit();
                        continue;
                    };
                    continue;
                }

                // udata always carries the *Connection pointer (set by registerRead at accept time).
                const conn: *Connection = @ptrFromInt(ev.udata);
                if (!conn.handleReadable()) conn.deinit();
            }
        }
    }
};

fn supportsKqueue() bool {
    return switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
        .dragonfly, .freebsd, .netbsd, .openbsd => true,
        else => false,
    };
}

fn eventLoopWorker(server: *Server, worker_index: usize) void {
    const listen_fd = createListenSocket(server.options, true) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("event-loop worker {d} failed to listen: {t}\n", .{ worker_index, err });
        }
        return;
    };
    defer _ = close(listen_fd);

    server.runEventLoop(listen_fd) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("event-loop worker {d} stopped: {t}\n", .{ worker_index, err });
        }
    };
}
fn ioUringWorker(server: *Server, worker_index: usize) void {
    if (comptime builtin.os.tag != .linux) return;
    const listen_fd = createListenSocket(server.options, true) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("io_uring worker {d} failed to listen: {t}\n", .{ worker_index, err });
        }
        return;
    };
    defer _ = close(listen_fd);
    @import("io_uring.zig").run(server, listen_fd) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("io_uring worker {d} stopped: {t}\n", .{ worker_index, err });
        }
    };
}

fn effectiveWorkerCount(configured: usize) usize {
    if (configured != 0) return @max(configured, 1);
    return @max(std.Thread.getCpuCount() catch 1, 1);
}

/// Resolve `Runtime.auto` against the host platform, returning a concrete runtime.
fn effectiveRuntime(requested: Runtime) Runtime {
    if (requested != .auto) return requested;
    return switch (builtin.os.tag) {
        .linux => .io_uring,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => .event_loop,
        .dragonfly, .freebsd, .netbsd, .openbsd => .event_loop,
        else => .thread_per_connection,
    };
}

pub fn serve(app: *app_mod.App, allocator: std.mem.Allocator, options: Options) !void {
    return serveGeneric(app.dispatcher(), allocator, options);
}

/// Drive the runtime with any dispatcher — not just `App`. Use this from
/// non-`App` consumers (turboAPI's Python FFI, merjs' SSR pipeline) by
/// constructing a `Dispatcher` with your own ctx + adapter functions.
pub fn serveGeneric(dispatcher: Dispatcher, allocator: std.mem.Allocator, options: Options) !void {
    var server = Server.init(dispatcher, allocator, options);
    defer server.deinit();
    try server.listenAndServe();
}

fn handleConnection(server: *Server, fd: c.fd_t) void {
    defer _ = close(fd);

    var input = InputBuffer{
        .buf = server.allocator.alloc(u8, server.options.read_buffer_size) catch return,
    };
    defer server.allocator.free(input.buf);

    const headers = server.allocator.alloc(request.HeaderPair, server.options.max_headers) catch return;
    defer server.allocator.free(headers);

    var arena = std.heap.ArenaAllocator.init(server.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    if ((input.readAppend(fd) catch return) == false) return;

    while (true) {
        const parsed = parseRequestHead(input.bytes(), headers) catch |err| switch (err) {
            error.IncompleteRequestHead => {
                if ((input.readAppend(fd) catch return) == false) return;
                continue;
            },
            else => {
                sendError(fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
                return;
            },
        };
        const body = readFullBody(req_allocator, fd, parsed) catch {
            sendError(fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
            return;
        };

        var req = request.Request.initPartsCached(
            req_allocator,
            parsed.method,
            parsed.target,
            parsed.path,
            parsed.query_string,
            parsed.headers,
            body.bytes,
            parsed.header_cache,
        );

        var res = server.dispatcher.handle(server.dispatcher.ctx, &req) catch {
            sendError(fd, status.HTTP_500_INTERNAL_SERVER_ERROR, "Internal Server Error") catch {};
            return;
        };

        const send_result = sendResponse(fd, &res, parsed.keep_alive, parsed.send_keep_alive_header, parsed.is_head);
        // All allocations for this request live in the arena; reset before next iteration.
        _ = arena.reset(.retain_capacity);
        send_result catch return;
        if (!parsed.keep_alive) return;
        input.consume(parsed.consumed_len);
        if (input.len == 0 and (input.readAppend(fd) catch return) == false) return;
    }
}

const Connection = struct {
    server: *Server,
    fd: c.fd_t,
    input: InputBuffer,
    headers: []request.HeaderPair,
    arena: std.heap.ArenaAllocator,
    write_buf: []u8,
    write_len: usize = 0,

    fn create(server: *Server, fd: c.fd_t) !*Connection {
        const conn = try server.allocator.create(Connection);
        errdefer server.allocator.destroy(conn);

        const buf = try server.allocator.alloc(u8, server.options.read_buffer_size);
        errdefer server.allocator.free(buf);

        const headers = try server.allocator.alloc(request.HeaderPair, server.options.max_headers);
        errdefer server.allocator.free(headers);

        const write_buf = try server.allocator.alloc(u8, server.options.write_buffer_size);
        errdefer server.allocator.free(write_buf);

        conn.* = .{
            .server = server,
            .fd = fd,
            .input = .{ .buf = buf },
            .headers = headers,
            .arena = std.heap.ArenaAllocator.init(server.allocator),
            .write_buf = write_buf,
        };
        return conn;
    }

    fn deinit(self: *Connection) void {
        self.arena.deinit();
        _ = close(self.fd);
        self.server.allocator.free(self.write_buf);
        self.server.allocator.free(self.headers);
        self.server.allocator.free(self.input.buf);
        self.server.allocator.destroy(self);
    }

    fn flushWrite(self: *Connection) !void {
        if (self.write_len == 0) return;
        const len = self.write_len;
        self.write_len = 0;
        try sendAll(self.fd, self.write_buf[0..len]);
    }

    fn appendFastJsonBytes(self: *Connection, body: []const u8) !void {
        const prefix = "HTTP/1.1 200 OK\r\nContent-Length: ";
        const middle = "\r\nContent-Type: application/json\r\n\r\n";
        const max_record_len = prefix.len + 20 + middle.len + body.len;

        if (max_record_len > self.write_buf.len) {
            // Larger than the per-connection batch buffer — flush and send directly.
            try self.flushWrite();
            return sendFastJsonBytes(self.fd, body);
        }
        if (self.write_len + max_record_len > self.write_buf.len) {
            try self.flushWrite();
        }

        var len = self.write_len;
        @memcpy(self.write_buf[len..][0..prefix.len], prefix);
        len += prefix.len;
        len += appendDecimal(self.write_buf[len..], body.len);
        @memcpy(self.write_buf[len..][0..middle.len], middle);
        len += middle.len;
        @memcpy(self.write_buf[len..][0..body.len], body);
        len += body.len;
        self.write_len = len;
    }

    /// Append already-rendered HTTP response bytes (status line + headers + body) to the
    /// per-connection batch buffer. Used by the static-route shortcut.
    fn appendStaticBytes(self: *Connection, bytes: []const u8) !void {
        if (bytes.len > self.write_buf.len) {
            try self.flushWrite();
            return sendAll(self.fd, bytes);
        }
        if (self.write_len + bytes.len > self.write_buf.len) {
            try self.flushWrite();
        }
        @memcpy(self.write_buf[self.write_len..][0..bytes.len], bytes);
        self.write_len += bytes.len;
    }

    fn dispatchResponse(
        self: *Connection,
        res: *const response.Response,
        keep_alive: bool,
        send_keep_alive_header: bool,
        is_head: bool,
    ) !void {
        if (canUseFastJsonBytes(res, keep_alive, send_keep_alive_header, is_head)) {
            return self.appendFastJsonBytes(res.body);
        }
        // Fallback path can't be batched (file/stream/custom headers); flush pending writes first.
        try self.flushWrite();
        return sendResponse(self.fd, res, keep_alive, send_keep_alive_header, is_head);
    }

    fn handleReadable(self: *Connection) bool {
        if ((self.input.readAppend(self.fd) catch return false) == false) return false;

        const req_allocator = self.arena.allocator();

        while (self.input.len > 0) {
            const parsed = parseRequestHead(self.input.bytes(), self.headers) catch |err| switch (err) {
                error.IncompleteRequestHead => {
                    self.flushWrite() catch return false;
                    return true;
                },
                else => {
                    self.flushWrite() catch {};
                    sendError(self.fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
                    return false;
                },
            };

            if (parsed.body.len < parsed.content_length and parsed.body_start + parsed.content_length <= self.input.capacity()) {
                self.flushWrite() catch return false;
                return true;
            }

            // ---- Static-bytes shortcut ----
            // For routes registered via app.getStaticJson, the response is fully pre-rendered
            // at registration. We bypass handler dispatch, Response construction, and the
            // canUseFastJsonBytes/format step entirely, and just memcpy bytes into write_buf.
            // This only fires when the request also has no body to drain, no middlewares in
            // play (we'd need to run them for correctness), and isn't HEAD (which would still
            // need to suppress the body).
            static_dispatch: {
                if (parsed.content_length != 0) break :static_dispatch;
                if (self.server.dispatcher.has_middleware(self.server.dispatcher.ctx)) break :static_dispatch;
                if (parsed.is_head) break :static_dispatch;
                const try_static = self.server.dispatcher.try_static_dispatch orelse break :static_dispatch;
                const static_bytes = try_static(self.server.dispatcher.ctx, parsed.method, parsed.path) orelse break :static_dispatch;
                self.appendStaticBytes(static_bytes) catch return false;
                self.input.consume(parsed.consumed_len);
                continue;
            }

            const body = readFullBody(req_allocator, self.fd, parsed) catch {
                self.flushWrite() catch {};
                sendError(self.fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
                return false;
            };

            var req = request.Request.initPartsCached(
                req_allocator,
                parsed.method,
                parsed.target,
                parsed.path,
                parsed.query_string,
                parsed.headers,
                body.bytes,
                parsed.header_cache,
            );

            var res = self.server.dispatcher.handle(self.server.dispatcher.ctx, &req) catch {
                self.flushWrite() catch {};
                sendError(self.fd, status.HTTP_500_INTERNAL_SERVER_ERROR, "Internal Server Error") catch {};
                return false;
            };

            const send_result = self.dispatchResponse(&res, parsed.keep_alive, parsed.send_keep_alive_header, parsed.is_head);
            // Arena owns request/response/body bytes for this request; reset before the next iteration.
            _ = self.arena.reset(.retain_capacity);
            send_result catch return false;
            if (!parsed.keep_alive) {
                self.flushWrite() catch {};
                return false;
            }
            self.input.consume(parsed.consumed_len);
        }
        self.flushWrite() catch return false;
        return true;
    }
};

const InputBuffer = struct {
    buf: []u8,
    head: usize = 0,
    len: usize = 0,

    fn bytes(self: *const InputBuffer) []const u8 {
        return self.buf[self.head .. self.head + self.len];
    }

    /// Total contiguous capacity available to the current logical buffer view, including
    /// reclaimable space at the head (which compaction would surface).
    fn capacity(self: *const InputBuffer) usize {
        return self.buf.len - self.head;
    }

    fn readAppend(self: *InputBuffer, fd: c.fd_t) !bool {
        // If there's no room at the tail, try to reclaim head space by compacting.
        if (self.head + self.len == self.buf.len) {
            if (self.head == 0) return error.RequestBufferFull;
            if (self.len > 0) {
                std.mem.copyForwards(u8, self.buf[0..self.len], self.buf[self.head .. self.head + self.len]);
            }
            self.head = 0;
        }
        const tail_start = self.head + self.len;
        const n = try recvOnce(fd, self.buf[tail_start..]);
        if (n == 0) return false;
        self.len += n;
        return true;
    }

    fn consume(self: *InputBuffer, amount: usize) void {
        if (amount >= self.len) {
            self.head = 0;
            self.len = 0;
            return;
        }
        // O(1) — just slide the head forward; compact lazily on next readAppend if needed.
        self.head += amount;
        self.len -= amount;
    }
};

pub const ParsedRequest = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    query_string: []const u8,
    headers: []const request.HeaderPair,
    header_cache: request.Request.HeaderCache,
    body: []const u8,
    body_start: usize,
    consumed_len: usize,
    content_length: usize,
    keep_alive: bool,
    send_keep_alive_header: bool,
    is_head: bool,
};

pub fn parseRequestHead(buf: []const u8, headers_buf: []request.HeaderPair) !ParsedRequest {
    const method_end = std.mem.indexOfScalar(u8, buf, ' ') orelse return error.IncompleteRequestHead;
    const target_start = method_end + 1;
    const target_end = std.mem.indexOfScalarPos(u8, buf, target_start, ' ') orelse return error.InvalidRequestLine;
    const version_start = target_end + 1;
    const first_line_end = std.mem.indexOfPos(u8, buf, version_start, "\r\n") orelse return error.IncompleteRequestHead;

    const method = buf[0..method_end];
    const target = buf[target_start..target_end];
    const version = buf[version_start..first_line_end];
    const query_pos = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_pos) |idx| target[0..idx] else target;
    const query_string = if (query_pos) |idx| target[idx + 1 ..] else "";

    // u64 compare for the literal "HTTP/1.1" — one load+cmp instead of 8 byte loads.
    const is_http11 = blk: {
        if (version.len != 8) break :blk false;
        const v: u64 = std.mem.readInt(u64, version[0..8], .little);
        const expect: u64 = std.mem.readInt(u64, "HTTP/1.1", .little);
        break :blk v == expect;
    };
    const is_head = method.len == 4 and method[0] == 'H' and method[1] == 'E' and method[2] == 'A' and method[3] == 'D';

    var keep_alive = is_http11;
    var send_keep_alive_header = false;
    var header_count: usize = 0;
    var header_cache = request.Request.HeaderCache.initForBuffer(headers_buf);
    var content_length: usize = 0;
    var pos = first_line_end + 2;
    var body_start: usize = 0;
    var body: []const u8 = "";

    while (true) {
        if (pos + 1 >= buf.len) return error.IncompleteRequestHead;
        if (buf[pos] == '\r' and buf[pos + 1] == '\n') {
            body_start = pos + 2;
            body = buf[body_start..];
            break;
        }
        if (header_count >= headers_buf.len) return error.TooManyHeaders;

        const line_start = pos;
        var colon: ?usize = null;
        while (true) : (pos += 1) {
            if (pos + 1 >= buf.len) return error.IncompleteRequestHead;
            if (buf[pos] == ':' and colon == null) colon = pos;
            if (buf[pos] == '\r') {
                if (buf[pos + 1] != '\n') return error.InvalidHeader;
                break;
            }
        }

        const line_end = pos;
        pos += 2;
        const colon_pos = colon orelse return error.InvalidHeader;
        if (colon_pos >= line_end) return error.InvalidHeader;

        const name = trimHeaderWhitespace(buf[line_start..colon_pos]);
        const value = trimHeaderWhitespace(buf[colon_pos + 1 .. line_end]);

        headers_buf[header_count] = .{ .name = name, .value = value };
        header_cache.observe(name, header_count);
        header_count += 1;

        // Length-bucket dispatch: only call eqlIgnoreCase when length matches a header we care about.
        switch (name.len) {
            10 => if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.eqlIgnoreCase(value, "close")) {
                    keep_alive = false;
                } else if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                    keep_alive = true;
                    send_keep_alive_header = !is_http11;
                }
            },
            14 => if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHeader;
            },
            else => {},
        }
    }

    const headers = headers_buf[0..header_count];
    header_cache.finish(headers);
    const body_len = @min(body.len, content_length);
    const consumed_len = if (body.len >= content_length) body_start + content_length else buf.len;

    return .{
        .method = method,
        .target = target,
        .path = path,
        .query_string = query_string,
        .headers = headers,
        .header_cache = header_cache,
        .body = body[0..body_len],
        .body_start = body_start,
        .consumed_len = consumed_len,
        .content_length = content_length,
        .keep_alive = keep_alive,
        .send_keep_alive_header = send_keep_alive_header,
        .is_head = is_head,
    };
}

fn trimHeaderWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) : (start += 1) {}
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) : (end -= 1) {}
    return value[start..end];
}

const BodyBuffer = struct {
    bytes: []const u8,
    owned: bool = false,

    fn deinit(self: BodyBuffer, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.bytes);
    }
};

fn readFullBody(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    parsed: ParsedRequest,
) !BodyBuffer {
    if (parsed.content_length == 0) return .{ .bytes = "" };
    if (parsed.body.len >= parsed.content_length) {
        return .{ .bytes = parsed.body[0..parsed.content_length] };
    }

    const body = try allocator.alloc(u8, parsed.content_length);
    errdefer allocator.free(body);
    @memcpy(body[0..parsed.body.len], parsed.body);

    var offset = parsed.body.len;
    while (offset < body.len) {
        const n = try recvOnce(fd, body[offset..]);
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }

    return .{ .bytes = body, .owned = true };
}

fn createListenSocket(options: Options, reuse_port: bool) !c.fd_t {
    const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
    switch (c.errno(fd)) {
        .SUCCESS => {},
        else => |err| return errnoError(err),
    }
    errdefer _ = close(fd);

    var reuse: c_int = 1;
    _ = c.setsockopt(
        fd,
        c.SOL.SOCKET,
        c.SO.REUSEADDR,
        &reuse,
        @sizeOf(@TypeOf(reuse)),
    );

    if (reuse_port and @hasDecl(c.SO, "REUSEPORT")) {
        _ = c.setsockopt(
            fd,
            c.SOL.SOCKET,
            c.SO.REUSEPORT,
            &reuse,
            @sizeOf(@TypeOf(reuse)),
        );
    }

    if (@hasDecl(c.SO, "NOSIGPIPE")) {
        var no_sigpipe: c_int = 1;
        _ = c.setsockopt(
            fd,
            c.SOL.SOCKET,
            c.SO.NOSIGPIPE,
            &no_sigpipe,
            @sizeOf(@TypeOf(no_sigpipe)),
        );
    }

    var addr: c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, options.port),
        .addr = @bitCast(options.host),
    };

    const bind_rc = c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in));
    switch (c.errno(bind_rc)) {
        .SUCCESS => {},
        else => |err| return errnoError(err),
    }

    const listen_rc = c.listen(fd, options.backlog);
    switch (c.errno(listen_rc)) {
        .SUCCESS => {},
        else => |err| return errnoError(err),
    }

    return fd;
}

fn registerRead(kq: c.fd_t, fd: c.fd_t, udata: usize) !void {
    var change = [_]c.Kevent{.{
        .ident = @intCast(fd),
        .filter = @intCast(c.EVFILT.READ),
        .flags = c.EV.ADD | c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    }};
    var ignored: [1]c.Kevent = undefined;
    const rc = c.kevent(kq, &change, change.len, &ignored, 0, null);
    switch (c.errno(rc)) {
        .SUCCESS => {},
        else => |err| return errnoError(err),
    }
}

fn configureAcceptedSocket(fd: c.fd_t) void {
    var enabled: c_int = 1;

    if (@hasDecl(c.SO, "NOSIGPIPE")) {
        _ = c.setsockopt(
            fd,
            c.SOL.SOCKET,
            c.SO.NOSIGPIPE,
            &enabled,
            @sizeOf(@TypeOf(enabled)),
        );
    }

    if (@hasDecl(c, "TCP") and @hasDecl(c.TCP, "NODELAY") and @hasDecl(c, "IPPROTO") and @hasDecl(c.IPPROTO, "TCP")) {
        _ = c.setsockopt(
            fd,
            c.IPPROTO.TCP,
            c.TCP.NODELAY,
            &enabled,
            @sizeOf(@TypeOf(enabled)),
        );
    }
}

fn recvOnce(fd: c.fd_t, buf: []u8) !usize {
    while (true) {
        const n = c.recv(fd, buf.ptr, buf.len, 0);
        switch (c.errno(n)) {
            .SUCCESS => return @intCast(n),
            .INTR => continue,
            .AGAIN => continue,
            else => |err| return errnoError(err),
        }
    }
}

pub fn sendResponse(fd: c.fd_t, res: *const response.Response, keep_alive: bool, send_keep_alive_header: bool, head_only: bool) !void {
    if (canUseFastJsonBytes(res, keep_alive, send_keep_alive_header, head_only)) {
        return sendFastJsonBytes(fd, res.body);
    }

    var sender = BufferedSender.init(fd);

    var scratch: [256]u8 = undefined;
    try sender.print(
        &scratch,
        "HTTP/1.1 {d} {s}\r\n",
        .{ res.status_code, status.text(res.status_code) },
    );

    const is_stream = res.body_kind == .stream;
    if (is_stream) {
        try sender.append("Transfer-Encoding: chunked\r\n");
    } else {
        const content_length: u64 = switch (res.body_kind) {
            .bytes => res.body.len,
            .file => res.file_size,
            .stream => unreachable,
        };
        try sender.print(&scratch, "Content-Length: {d}\r\n", .{content_length});
    }

    if (!keep_alive) {
        try sender.append("Connection: close\r\n");
    } else if (send_keep_alive_header) {
        try sender.append("Connection: keep-alive\r\n");
    }

    var has_content_type = false;
    for (res.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) has_content_type = true;
        try sender.append(header.name);
        try sender.append(": ");
        try sender.append(header.value);
        try sender.append("\r\n");
    }

    if (!has_content_type) {
        if (res.media_type) |media_type| {
            try sender.append("Content-Type: ");
            try sender.append(media_type);
            try sender.append("\r\n");
        }
    }

    try sender.append("\r\n");
    switch (res.body_kind) {
        .bytes => {
            if (!head_only) try sender.append(res.body);
            try sender.flush();
        },
        .file => {
            try sender.flush();
            if (!head_only) try sendFileBody(fd, res.file_path orelse return error.Unexpected, res.file_size);
        },
        .stream => {
            try sender.flush();
            if (head_only) return;
            var chunked = ChunkedSink{ .fd = fd };
            var ctx = response.StreamContext{
                .sink = &chunked,
                .write_fn = chunkedWrite,
                .flush_fn = chunkedFlush,
            };
            const writer = res.stream_writer orelse return error.Unexpected;
            try writer(&ctx);
            try ctx.flush();
            try sendAll(fd, "0\r\n\r\n");
        },
    }
}

pub fn canUseFastJsonBytes(res: *const response.Response, keep_alive: bool, send_keep_alive_header: bool, head_only: bool) bool {
    if (!keep_alive or send_keep_alive_header or head_only) return false;
    if (res.status_code != status.HTTP_200_OK) return false;
    if (res.body_kind != .bytes) return false;
    if (res.headers.items.len != 0) return false;
    const media_type = res.media_type orelse return false;
    return std.mem.eql(u8, media_type, "application/json");
}

fn sendFastJsonBytes(fd: c.fd_t, body: []const u8) !void {
    if (fastJsonBufferedLen(body.len)) |_| {
        return sendFastJsonBytesBuffered(fd, body);
    }
    if (comptime @hasDecl(c.SO, "NOSIGPIPE")) {
        return sendFastJsonBytesVectored(fd, body);
    }
    return sendFastJsonBytesBuffered(fd, body);
}

fn sendFastJsonBytesVectored(fd: c.fd_t, body: []const u8) !void {
    var len_buf: [20]u8 = undefined;
    const len_bytes = len_buf[0..appendDecimal(&len_buf, body.len)];

    const prefix = "HTTP/1.1 200 OK\r\nContent-Length: ";
    const middle = "\r\nContent-Type: application/json\r\n\r\n";
    const parts = [_][]const u8{ prefix, len_bytes, middle, body };
    try sendAllParts(fd, &parts);
}

fn sendFastJsonBytesBuffered(fd: c.fd_t, body: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var len: usize = 0;

    if (fastJsonBufferedLen(body.len)) |max_len| {
        const prefix = "HTTP/1.1 200 OK\r\nContent-Length: ";
        const middle = "\r\nContent-Type: application/json\r\n\r\n";
        @memcpy(buf[len..][0..prefix.len], prefix);
        len += prefix.len;
        len += appendDecimal(buf[len..], body.len);
        @memcpy(buf[len..][0..middle.len], middle);
        len += middle.len;
        @memcpy(buf[len..][0..body.len], body);
        len += body.len;

        std.debug.assert(len <= max_len);
        return sendAll(fd, buf[0..len]);
    } else {
        const prefix = "HTTP/1.1 200 OK\r\nContent-Length: ";
        const middle = "\r\nContent-Type: application/json\r\n\r\n";
        var sender = BufferedSender.init(fd);
        try sender.append(prefix);
        len = appendDecimal(buf[0..], body.len);
        try sender.append(buf[0..len]);
        try sender.append(middle);
        try sender.append(body);
        return sender.flush();
    }
}

fn fastJsonBufferedLen(body_len: usize) ?usize {
    const prefix_len = "HTTP/1.1 200 OK\r\nContent-Length: ".len;
    const middle_len = "\r\nContent-Type: application/json\r\n\r\n".len;
    const max_len = prefix_len + 20 + middle_len + body_len;
    return if (max_len <= 8192) max_len else null;
}

fn sendAllParts(fd: c.fd_t, parts: []const []const u8) !void {
    var iovecs: [8]posix.iovec_const = undefined;
    var iov_count: usize = 0;
    for (parts) |part| {
        if (part.len == 0) continue;
        iovecs[iov_count] = .{ .base = part.ptr, .len = part.len };
        iov_count += 1;
    }
    if (iov_count == 0) return;

    var index: usize = 0;
    var offset: usize = 0;
    while (index < iov_count) {
        var active: [8]posix.iovec_const = undefined;
        active[0] = .{
            .base = iovecs[index].base + offset,
            .len = iovecs[index].len - offset,
        };
        var active_count: usize = 1;
        var src = index + 1;
        while (src < iov_count) : (src += 1) {
            active[active_count] = iovecs[src];
            active_count += 1;
        }

        const n = c.writev(fd, &active, @intCast(active_count));
        switch (c.errno(n)) {
            .SUCCESS => {
                if (n == 0) return error.ConnectionClosed;
                var advanced: usize = @intCast(n);
                while (advanced > 0) {
                    const remaining = iovecs[index].len - offset;
                    if (advanced < remaining) {
                        offset += advanced;
                        break;
                    }
                    advanced -= remaining;
                    index += 1;
                    offset = 0;
                    if (index == iov_count) break;
                }
            },
            .INTR => continue,
            .AGAIN => continue,
            else => |err| return errnoError(err),
        }
    }
}

pub fn appendDecimal(out: []u8, value: usize) usize {
    if (value < 10) {
        out[0] = decimalDigit(value);
        return 1;
    }
    if (value < 100) {
        out[0] = decimalDigit(value / 10);
        out[1] = decimalDigit(value % 10);
        return 2;
    }
    if (value < 1000) {
        out[0] = decimalDigit(value / 100);
        out[1] = decimalDigit((value / 10) % 10);
        out[2] = decimalDigit(value % 10);
        return 3;
    }
    if (value < 10_000) {
        out[0] = decimalDigit(value / 1000);
        out[1] = decimalDigit((value / 100) % 10);
        out[2] = decimalDigit((value / 10) % 10);
        out[3] = decimalDigit(value % 10);
        return 4;
    }

    var tmp: [20]u8 = undefined;
    var n = value;
    var count: usize = 0;
    while (n > 0) : (count += 1) {
        tmp[count] = @intCast('0' + (n % 10));
        n /= 10;
    }

    for (0..count) |i| {
        out[i] = tmp[count - 1 - i];
    }
    return count;
}

fn decimalDigit(value: usize) u8 {
    return @intCast(@as(usize, '0') + value);
}

fn sendFileBody(fd: c.fd_t, path: []const u8, file_size: u64) !void {
    const file_fd = try posix.openat(c.AT.FDCWD, path, .{}, 0);
    defer _ = close(file_fd);

    if (comptime hasSendfile()) {
        return sendFileBodyZeroCopy(fd, file_fd, file_size) catch |err| switch (err) {
            error.Unexpected => sendFileBodyBuffered(fd, file_fd, file_size),
            else => err,
        };
    }
    return sendFileBodyBuffered(fd, file_fd, file_size);
}

fn hasSendfile() bool {
    return switch (builtin.os.tag) {
        .driverkit, .ios, .linux, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
        else => false,
    };
}

fn sendFileBodyZeroCopy(socket_fd: c.fd_t, file_fd: c.fd_t, file_size: u64) !void {
    switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            var offset: c.off_t = 0;
            var remaining = std.math.cast(c.off_t, file_size) orelse return error.Unexpected;
            while (remaining > 0) {
                var sent = remaining;
                const rc = c.sendfile(file_fd, socket_fd, offset, &sent, null, 0);
                if (sent > 0) {
                    offset += sent;
                    remaining -= sent;
                }
                switch (c.errno(rc)) {
                    .SUCCESS => {},
                    .INTR, .AGAIN => continue,
                    else => |err| return errnoError(err),
                }
            }
        },
        .linux => {
            var offset: c.off_t = 0;
            var remaining = std.math.cast(usize, file_size) orelse return error.Unexpected;
            while (remaining > 0) {
                const n = c.sendfile(socket_fd, file_fd, &offset, remaining);
                switch (c.errno(n)) {
                    .SUCCESS => {
                        if (n == 0) return error.ConnectionClosed;
                        remaining -= @intCast(n);
                    },
                    .INTR, .AGAIN => continue,
                    else => |err| return errnoError(err),
                }
            }
        },
        else => unreachable,
    }
}

fn sendFileBodyBuffered(fd: c.fd_t, file_fd: c.fd_t, file_size: u64) !void {
    var buf: [16 * 1024]u8 = undefined;
    var remaining = file_size;
    while (remaining > 0) {
        const max_read = @min(buf.len, remaining);
        const n = try posix.read(file_fd, buf[0..@intCast(max_read)]);
        if (n == 0) return error.UnexpectedEndOfFile;
        try sendAll(fd, buf[0..n]);
        remaining -= n;
    }
}

const ChunkedSink = struct {
    fd: c.fd_t,
};

fn chunkedWrite(sink: *anyopaque, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const chunked: *ChunkedSink = @ptrCast(@alignCast(sink));
    var header: [32]u8 = undefined;
    const header_bytes = try std.fmt.bufPrint(&header, "{x}\r\n", .{bytes.len});
    const parts = [_][]const u8{ header_bytes, bytes, "\r\n" };
    try sendAllParts(chunked.fd, &parts);
}

fn chunkedFlush(sink: *anyopaque) !void {
    _ = sink;
}

fn sendError(fd: c.fd_t, code: u16, message: []const u8) !void {
    var line_buf: [512]u8 = undefined;
    const response_bytes = try std.fmt.bufPrint(
        &line_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n{s}",
        .{ code, status.text(code), message.len, message },
    );
    try sendAll(fd, response_bytes);
}

fn sendAll(fd: c.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const flags = if (@hasDecl(c.MSG, "NOSIGNAL")) c.MSG.NOSIGNAL else 0;
        const n = c.send(fd, bytes[written..].ptr, bytes.len - written, flags);
        switch (c.errno(n)) {
            .SUCCESS => {
                if (n == 0) return error.ConnectionClosed;
                written += @intCast(n);
            },
            .INTR => continue,
            .AGAIN => continue,
            else => |err| return errnoError(err),
        }
    }
}

const BufferedSender = struct {
    fd: c.fd_t,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn init(fd: c.fd_t) BufferedSender {
        return .{ .fd = fd };
    }

    fn append(self: *BufferedSender, bytes: []const u8) !void {
        if (bytes.len > self.buf.len) {
            try self.flush();
            try sendAll(self.fd, bytes);
            return;
        }

        if (self.len + bytes.len > self.buf.len) {
            try self.flush();
        }

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn print(self: *BufferedSender, scratch: []u8, comptime fmt: []const u8, args: anytype) !void {
        const bytes = try std.fmt.bufPrint(scratch, fmt, args);
        try self.append(bytes);
    }

    fn flush(self: *BufferedSender) !void {
        if (self.len == 0) return;
        try sendAll(self.fd, self.buf[0..self.len]);
        self.len = 0;
    }
};

fn errnoError(err: c.E) error{ ConnectionClosed, Unexpected } {
    switch (err) {
        .CONNRESET, .PIPE, .NOTCONN => return error.ConnectionClosed,
        else => {},
    }
    if (builtin.mode == .Debug) {
        std.debug.print("unexpected errno: {t}\n", .{err});
    }
    return error.Unexpected;
}

test "parse HTTP request head" {
    var headers: [8]request.HeaderPair = undefined;
    const parsed = try parseRequestHead(
        "GET /users/42?verbose=true HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n",
        &headers,
    );

    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/users/42?verbose=true", parsed.target);
    try std.testing.expect(parsed.keep_alive);
    try std.testing.expect(!parsed.send_keep_alive_header);
    try std.testing.expectEqual(@as(usize, 2), parsed.headers.len);
    try std.testing.expectEqualStrings("Host", parsed.headers[0].name);
    try std.testing.expectEqualStrings("localhost", parsed.headers[0].value);
}

test "parse HTTP/1.0 explicit keep-alive" {
    var headers: [8]request.HeaderPair = undefined;
    const parsed = try parseRequestHead(
        "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
        &headers,
    );

    try std.testing.expect(parsed.keep_alive);
    try std.testing.expect(parsed.send_keep_alive_header);
}

test "parse HTTP request content length" {
    var headers: [8]request.HeaderPair = undefined;
    const parsed = try parseRequestHead(
        "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhelloextra",
        &headers,
    );

    try std.testing.expectEqualStrings("POST", parsed.method);
    try std.testing.expectEqual(@as(usize, 5), parsed.content_length);
    try std.testing.expectEqualStrings("hello", parsed.body);
}

test "parse HTTP request preserves pipelined bytes after body" {
    var headers: [8]request.HeaderPair = undefined;
    const bytes =
        "POST /upload HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello" ++
        "GET /next HTTP/1.1\r\n\r\n";
    const parsed = try parseRequestHead(bytes, &headers);

    try std.testing.expectEqual(@as(usize, 5), parsed.content_length);
    try std.testing.expectEqualStrings("hello", parsed.body);
    try std.testing.expectEqualStrings("GET /next HTTP/1.1\r\n\r\n", bytes[parsed.consumed_len..]);
}

test "parse HTTP request consumes zero-body request before pipeline" {
    var headers: [8]request.HeaderPair = undefined;
    const bytes = "GET / HTTP/1.1\r\n\r\nGET /next HTTP/1.1\r\n\r\n";
    const parsed = try parseRequestHead(bytes, &headers);

    try std.testing.expectEqual(@as(usize, 0), parsed.content_length);
    try std.testing.expectEqual(@as(usize, 0), parsed.body.len);
    try std.testing.expectEqualStrings("GET /next HTTP/1.1\r\n\r\n", bytes[parsed.consumed_len..]);
}
