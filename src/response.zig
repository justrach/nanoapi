const std = @import("std");
const c = std.c;
const posix = std.posix;
const status = @import("status.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ResponseOptions = struct {
    status_code: u16 = status.HTTP_200_OK,
    headers: []const Header = &.{},
    media_type: ?[]const u8 = null,
};

pub const CookieOptions = struct {
    max_age: ?i64 = null,
    expires: ?[]const u8 = null,
    path: []const u8 = "/",
    domain: ?[]const u8 = null,
    secure: bool = false,
    httponly: bool = false,
    samesite: ?[]const u8 = "lax",
};

pub const BodyKind = enum {
    bytes,
    file,
    stream,
};

pub const StreamWriteFn = *const fn (*StreamContext) anyerror!void;
pub const StreamSinkWriteFn = *const fn (*anyopaque, []const u8) anyerror!void;
pub const StreamSinkFlushFn = *const fn (*anyopaque) anyerror!void;

pub const StreamContext = struct {
    sink: *anyopaque,
    write_fn: StreamSinkWriteFn,
    flush_fn: ?StreamSinkFlushFn = null,

    pub fn write(self: *StreamContext, bytes: []const u8) !void {
        try self.write_fn(self.sink, bytes);
    }

    pub fn flush(self: *StreamContext) !void {
        if (self.flush_fn) |flush_fn| try flush_fn(self.sink);
    }
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16 = status.HTTP_200_OK,
    media_type: ?[]const u8 = null,
    media_type_owned: bool = false,
    body: []const u8 = &.{},
    body_owned: bool = false,
    body_kind: BodyKind = .bytes,
    file_path: ?[]const u8 = null,
    file_path_owned: bool = false,
    file_size: u64 = 0,
    stream_writer: ?StreamWriteFn = null,
    headers: std.ArrayList(Header) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        content: []const u8,
        options: ResponseOptions,
    ) !Response {
        const owned_body = try allocator.dupe(u8, content);
        return try fromOwnedBody(allocator, owned_body, options);
    }

    pub fn fromOwnedBody(
        allocator: std.mem.Allocator,
        body: []u8,
        options: ResponseOptions,
    ) !Response {
        var body_owned = true;
        errdefer if (body_owned) allocator.free(body);

        var res = Response{
            .allocator = allocator,
            .status_code = options.status_code,
            .media_type = options.media_type,
            .media_type_owned = false,
            .body = body,
            .body_owned = true,
            .body_kind = .bytes,
        };
        body_owned = false;
        errdefer res.deinit();
        for (options.headers) |h| {
            try res.addHeader(h.name, h.value);
        }
        return res;
    }

    pub fn fromStaticBody(
        allocator: std.mem.Allocator,
        body: []const u8,
        options: ResponseOptions,
    ) !Response {
        var res = Response{
            .allocator = allocator,
            .status_code = options.status_code,
            .media_type = options.media_type,
            .media_type_owned = false,
            .body = body,
            .body_owned = false,
            .body_kind = .bytes,
        };
        errdefer res.deinit();
        for (options.headers) |h| {
            try res.addHeader(h.name, h.value);
        }
        return res;
    }

    pub fn fromFilePath(
        allocator: std.mem.Allocator,
        path: []const u8,
        size: u64,
        options: ResponseOptions,
    ) !Response {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        var res = Response{
            .allocator = allocator,
            .status_code = options.status_code,
            .media_type = options.media_type,
            .media_type_owned = false,
            .body_kind = .file,
            .file_path = owned_path,
            .file_path_owned = true,
            .file_size = size,
        };
        errdefer res.deinit();
        for (options.headers) |h| {
            try res.addHeader(h.name, h.value);
        }
        return res;
    }

    pub fn fromStream(
        allocator: std.mem.Allocator,
        writer: StreamWriteFn,
        options: ResponseOptions,
    ) !Response {
        var res = Response{
            .allocator = allocator,
            .status_code = options.status_code,
            .media_type = options.media_type,
            .media_type_owned = false,
            .body_kind = .stream,
            .stream_writer = writer,
        };
        errdefer res.deinit();
        for (options.headers) |h| {
            try res.addHeader(h.name, h.value);
        }
        return res;
    }

    pub fn deinit(self: *Response) void {
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit(self.allocator);
        if (self.media_type_owned) {
            if (self.media_type) |m| self.allocator.free(m);
        }
        if (self.file_path_owned) {
            if (self.file_path) |p| self.allocator.free(p);
        }
        if (self.body_owned) self.allocator.free(self.body);
        self.* = undefined;
    }

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.headers.append(self.allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    fn addOwnedHeaderValue(self: *Response, name: []const u8, value: []u8) !void {
        errdefer self.allocator.free(value);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.headers.append(self.allocator, .{
            .name = owned_name,
            .value = value,
        });
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        for (self.headers.items) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                const owned = try self.allocator.dupe(u8, value);
                self.allocator.free(h.value);
                h.value = owned;
                return;
            }
        }
        try self.addHeader(name, value);
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        if (self.media_type) |m| {
            if (std.ascii.eqlIgnoreCase(name, "content-type")) return m;
        }
        return null;
    }

    pub fn setCookie(
        self: *Response,
        key: []const u8,
        value: []const u8,
        options: CookieOptions,
    ) !void {
        var cookie: std.ArrayList(u8) = .empty;
        errdefer cookie.deinit(self.allocator);

        try cookie.print(self.allocator, "{s}={s}; Path={s}", .{ key, value, options.path });
        if (options.max_age) |max_age| try cookie.print(self.allocator, "; Max-Age={d}", .{max_age});
        if (options.expires) |expires| try cookie.print(self.allocator, "; Expires={s}", .{expires});
        if (options.domain) |domain| try cookie.print(self.allocator, "; Domain={s}", .{domain});
        if (options.secure) try cookie.appendSlice(self.allocator, "; Secure");
        if (options.httponly) try cookie.appendSlice(self.allocator, "; HttpOnly");
        if (options.samesite) |samesite| try cookie.print(self.allocator, "; SameSite={s}", .{samesite});

        const owned = try cookie.toOwnedSlice(self.allocator);
        try self.addOwnedHeaderValue("set-cookie", owned);
    }

    pub fn deleteCookie(self: *Response, key: []const u8, options: CookieOptions) !void {
        var opts = options;
        opts.max_age = 0;
        try self.setCookie(key, "", opts);
    }
};

pub const StreamingResponse = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        writer: StreamWriteFn,
        options: ResponseOptions,
    ) !Response {
        return Response.fromStream(allocator, writer, options);
    }
};

pub const JSONResponse = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        content_json: []const u8,
        options: ResponseOptions,
    ) !Response {
        var opts = options;
        if (opts.media_type == null) opts.media_type = "application/json";
        return Response.init(allocator, content_json, opts);
    }

    pub fn static(
        allocator: std.mem.Allocator,
        content_json: []const u8,
        options: ResponseOptions,
    ) !Response {
        var opts = options;
        if (opts.media_type == null) opts.media_type = "application/json";
        return Response.fromStaticBody(allocator, content_json, opts);
    }
};

pub const HTMLResponse = struct {
    pub fn init(allocator: std.mem.Allocator, content: []const u8, options: ResponseOptions) !Response {
        var opts = options;
        if (opts.media_type == null) opts.media_type = "text/html";
        return Response.init(allocator, content, opts);
    }
};

pub const PlainTextResponse = struct {
    pub fn init(allocator: std.mem.Allocator, content: []const u8, options: ResponseOptions) !Response {
        var opts = options;
        if (opts.media_type == null) opts.media_type = "text/plain";
        return Response.init(allocator, content, opts);
    }
};

pub const RedirectResponse = struct {
    pub fn init(allocator: std.mem.Allocator, url: []const u8, options: ResponseOptions) !Response {
        var opts = options;
        if (opts.status_code == status.HTTP_200_OK) opts.status_code = status.HTTP_307_TEMPORARY_REDIRECT;
        var res = try Response.init(allocator, "", opts);
        errdefer res.deinit();
        try res.setHeader("location", url);
        return res;
    }
};

pub const FileResponse = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        filename: ?[]const u8,
        options: ResponseOptions,
    ) !Response {
        if (comptime @import("builtin").os.tag == .linux) {
            // FileResponse currently relies on std.c-style fstat which isn't wired
            // through this Zig version's std.os.linux. Until that's plumbed, callers
            // on Linux must construct Responses with a known content size via
            // Response.fromFilePath directly.
            return error.FileResponseNotSupportedOnLinux;
        }
        const fd = try posix.openat(c.AT.FDCWD, path, .{}, 0);
        defer _ = c.close(fd);

        var stat_info: c.Stat = undefined;
        if (c.fstat(fd, &stat_info) != 0) return error.Unexpected;
        if (stat_info.size < 0) return error.Unexpected;

        var opts = options;
        if (opts.media_type == null) opts.media_type = guessMediaType(path);
        var res = try Response.fromFilePath(allocator, path, @intCast(stat_info.size), opts);
        errdefer res.deinit();

        if (filename) |name| {
            const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{name});
            defer allocator.free(disposition);
            try res.setHeader("content-disposition", disposition);
        }

        return res;
    }
};

pub const EventSourceResponse = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        writer: StreamWriteFn,
        options: ResponseOptions,
    ) !Response {
        var opts = options;
        if (opts.media_type == null) opts.media_type = "text/event-stream";
        var res = try Response.fromStream(allocator, writer, opts);
        errdefer res.deinit();
        if (res.header("cache-control") == null) try res.setHeader("cache-control", "no-cache");
        if (res.header("x-accel-buffering") == null) try res.setHeader("x-accel-buffering", "no");
        return res;
    }
};

pub const LLMStreamResponse = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        writer: StreamWriteFn,
        options: ResponseOptions,
    ) !Response {
        return EventSourceResponse.init(allocator, writer, options);
    }
};

pub const SseWriter = struct {
    ctx: *StreamContext,

    pub fn init(ctx: *StreamContext) SseWriter {
        return .{ .ctx = ctx };
    }

    pub fn event(
        self: *SseWriter,
        name: ?[]const u8,
        data: []const u8,
        id: ?[]const u8,
    ) !void {
        if (try self.eventBuffered(name, data, id)) return;
        try self.eventSlow(name, data, id);
    }

    fn eventBuffered(
        self: *SseWriter,
        name: ?[]const u8,
        data: []const u8,
        id: ?[]const u8,
    ) !bool {
        var buf: [1024]u8 = undefined;
        var len: usize = 0;

        if (id) |value| {
            if (!appendSseBytes(&buf, &len, "id: ") or
                !appendSseBytes(&buf, &len, value) or
                !appendSseBytes(&buf, &len, "\n"))
            {
                return false;
            }
        }
        if (name) |value| {
            if (!appendSseBytes(&buf, &len, "event: ") or
                !appendSseBytes(&buf, &len, value) or
                !appendSseBytes(&buf, &len, "\n"))
            {
                return false;
            }
        }

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (!appendSseBytes(&buf, &len, "data: ") or
                !appendSseBytes(&buf, &len, line) or
                !appendSseBytes(&buf, &len, "\n"))
            {
                return false;
            }
        }
        if (!appendSseBytes(&buf, &len, "\n")) return false;

        try self.ctx.write(buf[0..len]);
        try self.ctx.flush();
        return true;
    }

    fn eventSlow(
        self: *SseWriter,
        name: ?[]const u8,
        data: []const u8,
        id: ?[]const u8,
    ) !void {
        if (id) |value| {
            try self.ctx.write("id: ");
            try self.ctx.write(value);
            try self.ctx.write("\n");
        }
        if (name) |value| {
            try self.ctx.write("event: ");
            try self.ctx.write(value);
            try self.ctx.write("\n");
        }

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            try self.ctx.write("data: ");
            try self.ctx.write(line);
            try self.ctx.write("\n");
        }
        try self.ctx.write("\n");
        try self.ctx.flush();
    }

    pub fn retry(self: *SseWriter, ms: u64) !void {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "retry: {d}\n\n", .{ms});
        try self.ctx.write(line);
        try self.ctx.flush();
    }

    pub fn comment(self: *SseWriter, text: []const u8) !void {
        try self.ctx.write(": ");
        try self.ctx.write(text);
        try self.ctx.write("\n\n");
        try self.ctx.flush();
    }
};

pub const LLMStreamWriter = struct {
    sse: SseWriter,

    pub fn init(ctx: *StreamContext) LLMStreamWriter {
        return .{ .sse = SseWriter.init(ctx) };
    }

    pub fn token(self: *LLMStreamWriter, content: []const u8) !void {
        try self.sse.event(null, content, null);
    }

    pub fn event(self: *LLMStreamWriter, name: []const u8, data: []const u8) !void {
        try self.sse.event(name, data, null);
    }

    pub fn errorMessage(self: *LLMStreamWriter, message: []const u8) !void {
        try self.sse.event("error", message, null);
    }

    pub fn done(self: *LLMStreamWriter) !void {
        try self.sse.event(null, "[DONE]", null);
    }
};

fn appendSseBytes(buf: []u8, len: *usize, bytes: []const u8) bool {
    if (len.* + bytes.len > buf.len) return false;
    @memcpy(buf[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
    return true;
}

pub fn jsonError(
    allocator: std.mem.Allocator,
    status_code: u16,
    detail: []const u8,
    headers: []const Header,
) !Response {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"detail\":");
    try appendJsonString(&body, allocator, detail);
    try body.append(allocator, '}');

    const owned = try body.toOwnedSlice(allocator);
    return Response.fromOwnedBody(allocator, owned, .{
        .status_code = status_code,
        .headers = headers,
        .media_type = "application/json",
    });
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

fn guessMediaType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    return "application/octet-stream";
}

test "streaming and SSE response helpers" {
    const allocator = std.testing.allocator;

    const Handler = struct {
        fn stream(ctx: *StreamContext) !void {
            var sse = SseWriter.init(ctx);
            try sse.event("ready", "hello\nworld", "1");
        }
    };

    var res = try EventSourceResponse.init(allocator, Handler.stream, .{});
    defer res.deinit();
    try std.testing.expectEqual(BodyKind.stream, res.body_kind);
    try std.testing.expectEqualStrings("text/event-stream", res.header("content-type").?);
    try std.testing.expectEqualStrings("no-cache", res.header("cache-control").?);

    const Sink = struct {
        out: std.ArrayList(u8) = .empty,

        fn write(ptr: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.out.appendSlice(std.testing.allocator, bytes);
        }

        fn flush(ptr: *anyopaque) !void {
            _ = ptr;
        }
    };

    var sink = Sink{};
    defer sink.out.deinit(allocator);
    var ctx = StreamContext{
        .sink = &sink,
        .write_fn = Sink.write,
        .flush_fn = Sink.flush,
    };
    try Handler.stream(&ctx);
    try std.testing.expectEqualStrings(
        "id: 1\nevent: ready\ndata: hello\ndata: world\n\n",
        sink.out.items,
    );
}

test "LLM stream response emits token and done SSE frames" {
    const allocator = std.testing.allocator;

    const Handler = struct {
        fn stream(ctx: *StreamContext) !void {
            var llm = LLMStreamWriter.init(ctx);
            try llm.token("hel");
            try llm.token("lo");
            try llm.done();
        }
    };

    var res = try LLMStreamResponse.init(allocator, Handler.stream, .{});
    defer res.deinit();
    try std.testing.expectEqual(BodyKind.stream, res.body_kind);
    try std.testing.expectEqualStrings("text/event-stream", res.header("content-type").?);

    const Sink = struct {
        out: std.ArrayList(u8) = .empty,

        fn write(ptr: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.out.appendSlice(std.testing.allocator, bytes);
        }

        fn flush(ptr: *anyopaque) !void {
            _ = ptr;
        }
    };

    var sink = Sink{};
    defer sink.out.deinit(allocator);
    var ctx = StreamContext{
        .sink = &sink,
        .write_fn = Sink.write,
        .flush_fn = Sink.flush,
    };
    try Handler.stream(&ctx);
    try std.testing.expectEqualStrings(
        "data: hel\n\ndata: lo\n\ndata: [DONE]\n\n",
        sink.out.items,
    );
}

test "file responses keep file payload out of memory" {
    const allocator = std.testing.allocator;
    var res = try Response.fromFilePath(allocator, "README.md", 123, .{ .media_type = "text/markdown" });
    defer res.deinit();

    try std.testing.expectEqual(BodyKind.file, res.body_kind);
    try std.testing.expectEqual(@as(u64, 123), res.file_size);
    try std.testing.expectEqualStrings("README.md", res.file_path.?);
    try std.testing.expectEqualStrings("text/markdown", res.header("content-type").?);
    try std.testing.expectEqual(@as(usize, 0), res.body.len);
}
