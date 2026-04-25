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
    backlog: c_uint = 1024,
    read_buffer_size: usize = 16 * 1024,
    max_headers: usize = 64,
    runtime: Runtime = .auto,
};

pub const Runtime = enum {
    auto,
    event_loop,
    thread_per_connection,
};

pub const Server = struct {
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    options: Options,
    listen_fd: c.fd_t = -1,

    pub fn init(app: *app_mod.App, allocator: std.mem.Allocator, options: Options) Server {
        return .{
            .app = app,
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
        if (self.useEventLoop()) {
            return self.listenAndServeEventLoop();
        }
        return self.listenAndServeThreaded();
    }

    fn useEventLoop(self: *const Server) bool {
        return switch (self.options.runtime) {
            .event_loop => true,
            .thread_per_connection => false,
            .auto => switch (builtin.os.tag) {
                .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
                .dragonfly, .freebsd, .netbsd, .openbsd => true,
                else => false,
            },
        };
    }

    fn listenAndServeThreaded(self: *Server) !void {
        self.listen_fd = try createListenSocket(self.options);

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
        self.listen_fd = try createListenSocket(self.options);

        const kq = c.kqueue();
        switch (c.errno(kq)) {
            .SUCCESS => {},
            else => |err| return errnoError(err),
        }
        defer _ = close(kq);

        try registerRead(kq, self.listen_fd, 0);

        var connections = std.AutoHashMap(c.fd_t, *Connection).init(self.allocator);
        defer {
            var it = connections.valueIterator();
            while (it.next()) |conn| conn.*.deinit();
            connections.deinit();
        }

        var events: [1024]c.Kevent = undefined;
        while (true) {
            const n = c.kevent(kq, @as([*]const c.Kevent, @ptrCast(&events)), 0, &events, events.len, null);
            switch (c.errno(n)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |err| return errnoError(err),
            }

            for (events[0..@intCast(n)]) |ev| {
                if (ev.ident == @as(usize, @intCast(self.listen_fd))) {
                    const fd = c.accept(self.listen_fd, null, null);
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
                    errdefer conn.deinit();
                    connections.put(client_fd, conn) catch {
                        conn.deinit();
                        continue;
                    };
                    registerRead(kq, client_fd, @intFromPtr(conn)) catch {
                        if (connections.remove(client_fd)) conn.deinit();
                        continue;
                    };
                    continue;
                }

                const conn: *Connection = if (ev.udata != 0)
                    @ptrFromInt(ev.udata)
                else
                    connections.get(@intCast(ev.ident)) orelse continue;

                if (!conn.handleReadable()) {
                    _ = connections.remove(conn.fd);
                    conn.deinit();
                }
            }
        }
    }
};

pub fn serve(app: *app_mod.App, allocator: std.mem.Allocator, options: Options) !void {
    var server = Server.init(app, allocator, options);
    defer server.deinit();
    try server.listenAndServe();
}

fn handleConnection(server: *Server, fd: c.fd_t) void {
    defer _ = close(fd);

    const buf = server.allocator.alloc(u8, server.options.read_buffer_size) catch return;
    defer server.allocator.free(buf);

    const headers = server.allocator.alloc(request.HeaderPair, server.options.max_headers) catch return;
    defer server.allocator.free(headers);

    while (true) {
        const n = recvOnce(fd, buf) catch return;
        if (n == 0) return;

        const parsed = parseRequestHead(buf[0..n], headers) catch {
            sendError(fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
            return;
        };
        const body = readFullBody(server.allocator, fd, parsed) catch {
            sendError(fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
            return;
        };
        defer body.deinit(server.allocator);

        var req = request.Request.initParts(
            server.allocator,
            parsed.method,
            parsed.target,
            parsed.path,
            parsed.query_string,
            parsed.headers,
            body.bytes,
        );

        var res = server.app.handle(&req) catch {
            sendError(fd, status.HTTP_500_INTERNAL_SERVER_ERROR, "Internal Server Error") catch {};
            return;
        };
        defer res.deinit();

        sendResponse(fd, &res, parsed.keep_alive, parsed.send_keep_alive_header, std.mem.eql(u8, parsed.method, "HEAD")) catch return;
        if (!parsed.keep_alive) return;
    }
}

const Connection = struct {
    server: *Server,
    fd: c.fd_t,
    buf: []u8,
    headers: []request.HeaderPair,

    fn create(server: *Server, fd: c.fd_t) !*Connection {
        const conn = try server.allocator.create(Connection);
        errdefer server.allocator.destroy(conn);

        const buf = try server.allocator.alloc(u8, server.options.read_buffer_size);
        errdefer server.allocator.free(buf);

        const headers = try server.allocator.alloc(request.HeaderPair, server.options.max_headers);
        errdefer server.allocator.free(headers);

        conn.* = .{
            .server = server,
            .fd = fd,
            .buf = buf,
            .headers = headers,
        };
        return conn;
    }

    fn deinit(self: *Connection) void {
        _ = close(self.fd);
        self.server.allocator.free(self.headers);
        self.server.allocator.free(self.buf);
        self.server.allocator.destroy(self);
    }

    fn handleReadable(self: *Connection) bool {
        const n = recvOnce(self.fd, self.buf) catch return false;
        if (n == 0) return false;

        const parsed = parseRequestHead(self.buf[0..n], self.headers) catch {
            sendError(self.fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
            return false;
        };
        const body = readFullBody(self.server.allocator, self.fd, parsed) catch {
            sendError(self.fd, status.HTTP_400_BAD_REQUEST, "Bad Request") catch {};
            return false;
        };
        defer body.deinit(self.server.allocator);

        var req = request.Request.initParts(
            self.server.allocator,
            parsed.method,
            parsed.target,
            parsed.path,
            parsed.query_string,
            parsed.headers,
            body.bytes,
        );

        var res = self.server.app.handle(&req) catch {
            sendError(self.fd, status.HTTP_500_INTERNAL_SERVER_ERROR, "Internal Server Error") catch {};
            return false;
        };
        defer res.deinit();

        sendResponse(self.fd, &res, parsed.keep_alive, parsed.send_keep_alive_header, std.mem.eql(u8, parsed.method, "HEAD")) catch return false;
        return parsed.keep_alive;
    }
};

const ParsedRequest = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    query_string: []const u8,
    headers: []const request.HeaderPair,
    body: []const u8,
    content_length: usize,
    keep_alive: bool,
    send_keep_alive_header: bool,
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
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_start) |idx| target[0..idx] else target;
    const query_string = if (query_start) |idx| target[idx + 1 ..] else "";

    var keep_alive = std.mem.eql(u8, version, "HTTP/1.1");
    var send_keep_alive_header = false;
    var header_count: usize = 0;
    var content_length: usize = 0;
    var pos = first_line_end + 2;
    var body: []const u8 = "";

    while (true) {
        if (pos + 1 >= buf.len) return error.IncompleteRequestHead;
        if (buf[pos] == '\r' and buf[pos + 1] == '\n') {
            body = buf[pos + 2 ..];
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
        header_count += 1;

        if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                keep_alive = true;
                send_keep_alive_header = !std.mem.eql(u8, version, "HTTP/1.1");
            }
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHeader;
        }
    }

    return .{
        .method = method,
        .target = target,
        .path = path,
        .query_string = query_string,
        .headers = headers_buf[0..header_count],
        .body = if (body.len > content_length) body[0..content_length] else body,
        .content_length = content_length,
        .keep_alive = keep_alive,
        .send_keep_alive_header = send_keep_alive_header,
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

fn createListenSocket(options: Options) !c.fd_t {
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

fn sendResponse(fd: c.fd_t, res: *const response.Response, keep_alive: bool, send_keep_alive_header: bool, head_only: bool) !void {
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

fn canUseFastJsonBytes(res: *const response.Response, keep_alive: bool, send_keep_alive_header: bool, head_only: bool) bool {
    if (!keep_alive or send_keep_alive_header or head_only) return false;
    if (res.status_code != status.HTTP_200_OK) return false;
    if (res.body_kind != .bytes) return false;
    if (res.headers.items.len != 0) return false;
    const media_type = res.media_type orelse return false;
    return std.mem.eql(u8, media_type, "application/json");
}

fn sendFastJsonBytes(fd: c.fd_t, body: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;

    const prefix = "HTTP/1.1 200 OK\r\nContent-Length: ";
    const middle = "\r\nContent-Type: application/json\r\n\r\n";
    const max_len = prefix.len + 20 + middle.len + body.len;
    if (max_len > buf.len) {
        var sender = BufferedSender.init(fd);
        try sender.append(prefix);
        len = appendDecimal(buf[0..], body.len);
        try sender.append(buf[0..len]);
        try sender.append(middle);
        try sender.append(body);
        return sender.flush();
    }

    @memcpy(buf[len..][0..prefix.len], prefix);
    len += prefix.len;
    len += appendDecimal(buf[len..], body.len);
    @memcpy(buf[len..][0..middle.len], middle);
    len += middle.len;
    @memcpy(buf[len..][0..body.len], body);
    len += body.len;

    try sendAll(fd, buf[0..len]);
}

fn appendDecimal(out: []u8, value: usize) usize {
    if (value == 0) {
        out[0] = '0';
        return 1;
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

fn sendFileBody(fd: c.fd_t, path: []const u8, file_size: u64) !void {
    const file_fd = try posix.openat(c.AT.FDCWD, path, .{}, 0);
    defer _ = close(file_fd);

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
    try sendAll(chunked.fd, header_bytes);
    try sendAll(chunked.fd, bytes);
    try sendAll(chunked.fd, "\r\n");
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
