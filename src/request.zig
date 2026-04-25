const std = @import("std");
const core = @import("turboapi-core");

pub const HeaderPair = core.HeaderPair;

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: []const u8,
    target: []const u8,
    path: []const u8,
    query_string: []const u8,
    headers: []const HeaderPair = &.{},
    body: []const u8 = "",
    path_params: ?*const core.RouteParams = null,
    header_cache: HeaderCache = .{},

    const CommonHeader = enum {
        accept,
        authorization,
        content_type,
        cookie,
        host,
        user_agent,
    };

    const CachedHeader = union(enum) {
        hit: []const u8,
        miss,
        invalid,
    };

    const HeaderCache = struct {
        source_ptr: ?[*]const HeaderPair = null,
        source_len: usize = 0,
        accept: ?usize = null,
        authorization: ?usize = null,
        content_type: ?usize = null,
        cookie: ?usize = null,
        host: ?usize = null,
        user_agent: ?usize = null,

        fn init(headers: []const HeaderPair) HeaderCache {
            var cache: HeaderCache = .{
                .source_ptr = if (headers.len == 0) null else headers.ptr,
                .source_len = headers.len,
            };
            for (headers, 0..) |h, idx| {
                if (commonHeaderId(h.name)) |id| cache.setFirst(id, idx);
            }
            return cache;
        }

        fn lookup(self: *const HeaderCache, headers: []const HeaderPair, id: CommonHeader) CachedHeader {
            if (!self.matches(headers)) return .invalid;
            const idx = self.index(id) orelse return .miss;
            if (idx >= headers.len) return .invalid;

            const h = headers[idx];
            if (!commonHeaderMatches(h.name, id)) return .invalid;
            return .{ .hit = h.value };
        }

        fn matches(self: *const HeaderCache, headers: []const HeaderPair) bool {
            if (headers.len != self.source_len) return false;
            if (headers.len == 0) return true;
            const source_ptr = self.source_ptr orelse return false;
            return source_ptr == headers.ptr;
        }

        fn index(self: *const HeaderCache, id: CommonHeader) ?usize {
            return switch (id) {
                .accept => self.accept,
                .authorization => self.authorization,
                .content_type => self.content_type,
                .cookie => self.cookie,
                .host => self.host,
                .user_agent => self.user_agent,
            };
        }

        fn setFirst(self: *HeaderCache, id: CommonHeader, idx: usize) void {
            switch (id) {
                .accept => {
                    if (self.accept == null) self.accept = idx;
                },
                .authorization => {
                    if (self.authorization == null) self.authorization = idx;
                },
                .content_type => {
                    if (self.content_type == null) self.content_type = idx;
                },
                .cookie => {
                    if (self.cookie == null) self.cookie = idx;
                },
                .host => {
                    if (self.host == null) self.host = idx;
                },
                .user_agent => {
                    if (self.user_agent == null) self.user_agent = idx;
                },
            }
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        headers: []const HeaderPair,
        body: []const u8,
    ) Request {
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        const path = if (query_start) |idx| target[0..idx] else target;
        const query = if (query_start) |idx| target[idx + 1 ..] else "";
        return .{
            .allocator = allocator,
            .method = method,
            .target = target,
            .path = path,
            .query_string = query,
            .headers = headers,
            .body = body,
            .header_cache = HeaderCache.init(headers),
        };
    }

    pub fn initParts(
        allocator: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        path: []const u8,
        query_string: []const u8,
        headers: []const HeaderPair,
        body: []const u8,
    ) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .target = target,
            .path = path,
            .query_string = query_string,
            .headers = headers,
            .body = body,
            .header_cache = HeaderCache.init(headers),
        };
    }

    pub fn setPathParams(self: *Request, params: *const core.RouteParams) void {
        self.path_params = params;
    }

    pub fn pathParam(self: *const Request, name: []const u8) ?[]const u8 {
        const params = self.path_params orelse return null;
        return params.get(name);
    }

    pub fn pathInt(self: *const Request, name: []const u8) ?i64 {
        const params = self.path_params orelse return null;
        return params.getInt(name);
    }

    pub fn queryParam(self: *const Request, name: []const u8) ?[]const u8 {
        return core.http.queryStringGet(self.query_string, name);
    }

    pub fn queryInt(self: *const Request, name: []const u8) !?i64 {
        const raw = self.queryParam(name) orelse return null;
        return try std.fmt.parseInt(i64, raw, 10);
    }

    pub fn queryFloat(self: *const Request, name: []const u8) !?f64 {
        const raw = self.queryParam(name) orelse return null;
        return try std.fmt.parseFloat(f64, raw);
    }

    pub fn queryBool(self: *const Request, name: []const u8) ?bool {
        const raw = self.queryParam(name) orelse return null;
        if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        return null;
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        if (commonHeaderId(name)) |id| return self.commonHeader(id);
        return self.findHeader(name);
    }

    pub fn cookie(self: *const Request, name: []const u8) ?[]const u8 {
        const cookie_header = self.commonHeader(.cookie) orelse return null;
        var it = std.mem.splitScalar(u8, cookie_header, ';');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            if (std.mem.eql(u8, key, name)) {
                return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
            }
        }
        return null;
    }

    pub fn percentDecodeQuery(self: *const Request, value: []const u8, buffer: []u8) []u8 {
        _ = self;
        return core.http.percentDecode(value, buffer);
    }

    fn commonHeader(self: *const Request, id: CommonHeader) ?[]const u8 {
        switch (self.header_cache.lookup(self.headers, id)) {
            .hit => |value| return value,
            .miss => return null,
            .invalid => return self.findHeader(commonHeaderName(id)),
        }
    }

    fn findHeader(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

fn commonHeaderId(name: []const u8) ?Request.CommonHeader {
    return switch (name.len) {
        4 => if (std.ascii.eqlIgnoreCase(name, "host")) .host else null,
        6 => if (std.ascii.eqlIgnoreCase(name, "accept"))
            .accept
        else if (std.ascii.eqlIgnoreCase(name, "cookie"))
            .cookie
        else
            null,
        10 => if (std.ascii.eqlIgnoreCase(name, "user-agent")) .user_agent else null,
        12 => if (std.ascii.eqlIgnoreCase(name, "content-type")) .content_type else null,
        13 => if (std.ascii.eqlIgnoreCase(name, "authorization")) .authorization else null,
        else => null,
    };
}

fn commonHeaderName(id: Request.CommonHeader) []const u8 {
    return switch (id) {
        .accept => "accept",
        .authorization => "authorization",
        .content_type => "content-type",
        .cookie => "cookie",
        .host => "host",
        .user_agent => "user-agent",
    };
}

fn commonHeaderMatches(name: []const u8, id: Request.CommonHeader) bool {
    return std.ascii.eqlIgnoreCase(name, commonHeaderName(id));
}

test "Request caches common headers from initParts" {
    const headers = [_]HeaderPair{
        .{ .name = "X-Trace-Id", .value = "trace-1" },
        .{ .name = "Authorization", .value = "Bearer token-123" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Cookie", .value = "session=abc123; theme = dark" },
    };
    const req = Request.initParts(
        std.testing.allocator,
        "POST",
        "/submit",
        "/submit",
        "",
        &headers,
        "{}",
    );

    try std.testing.expect(req.header_cache.authorization != null);
    try std.testing.expect(req.header_cache.content_type != null);
    try std.testing.expect(req.header_cache.cookie != null);
    try std.testing.expectEqualStrings("Bearer token-123", req.header("authorization").?);
    try std.testing.expectEqualStrings("application/json", req.header("CONTENT-TYPE").?);
    try std.testing.expectEqualStrings("trace-1", req.header("x-trace-id").?);
    try std.testing.expectEqualStrings("dark", req.cookie("theme").?);
}

test "Request common header cache preserves first-match semantics" {
    const headers = [_]HeaderPair{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Cookie", .value = "session=first" },
        .{ .name = "cookie", .value = "session=second" },
    };
    const req = Request.init(std.testing.allocator, "GET", "/items?limit=1", &headers, "");

    try std.testing.expectEqualStrings("/items", req.path);
    try std.testing.expectEqualStrings("limit=1", req.query_string);
    try std.testing.expectEqualStrings("text/plain", req.header("CONTENT-TYPE").?);
    try std.testing.expectEqualStrings("first", req.cookie("session").?);
}

test "Request common headers fall back for struct literals without cache" {
    const headers = [_]HeaderPair{
        .{ .name = "Authorization", .value = "Bearer literal" },
        .{ .name = "Cookie", .value = "session=literal" },
    };
    const req: Request = .{
        .allocator = std.testing.allocator,
        .method = "GET",
        .target = "/",
        .path = "/",
        .query_string = "",
        .headers = &headers,
    };

    try std.testing.expectEqualStrings("Bearer literal", req.header("authorization").?);
    try std.testing.expectEqualStrings("literal", req.cookie("session").?);
}
