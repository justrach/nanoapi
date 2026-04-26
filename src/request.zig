const std = @import("std");
const core = @import("turboapi-core");

pub const HeaderPair = core.HeaderPair;

pub const FormField = struct {
    name: []const u8,
    value: []const u8,
};

pub const UploadFile = struct {
    field_name: []const u8,
    filename: []const u8,
    content_type: ?[]const u8 = null,
    content: []const u8,
};

pub const FormData = struct {
    allocator: std.mem.Allocator,
    fields: std.ArrayList(FormField) = .empty,
    files: std.ArrayList(UploadFile) = .empty,

    pub fn init(allocator: std.mem.Allocator) FormData {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FormData) void {
        self.files.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn field(self: *const FormData, name: []const u8) ?[]const u8 {
        for (self.fields.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }

    pub fn file(self: *const FormData, name: []const u8) ?UploadFile {
        for (self.files.items) |item| {
            if (std.mem.eql(u8, item.field_name, name)) return item;
        }
        return null;
    }
};

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

    pub const CommonHeader = enum {
        accept,
        authorization,
        content_type,
        cookie,
        host,
        user_agent,
    };

    pub const CachedHeader = union(enum) {
        hit: []const u8,
        miss,
        invalid,
    };

    pub const HeaderCache = struct {
        source_ptr: ?[*]const HeaderPair = null,
        source_len: usize = 0,
        accept: ?usize = null,
        authorization: ?usize = null,
        content_type: ?usize = null,
        cookie: ?usize = null,
        host: ?usize = null,
        user_agent: ?usize = null,

        pub fn init(headers: []const HeaderPair) HeaderCache {
            var cache = initForBuffer(headers);
            for (headers, 0..) |h, idx| {
                cache.observe(h.name, idx);
            }
            cache.finish(headers);
            return cache;
        }

        pub fn initForBuffer(headers: []const HeaderPair) HeaderCache {
            return .{
                .source_ptr = if (headers.len == 0) null else headers.ptr,
            };
        }

        pub fn finish(self: *HeaderCache, headers: []const HeaderPair) void {
            self.source_ptr = if (headers.len == 0) null else headers.ptr;
            self.source_len = headers.len;
        }

        pub fn observe(self: *HeaderCache, name: []const u8, idx: usize) void {
            if (commonHeaderId(name)) |id| self.setFirst(id, idx);
        }

        pub fn lookup(self: *const HeaderCache, headers: []const HeaderPair, id: CommonHeader) CachedHeader {
            if (!self.matches(headers)) return .invalid;
            const idx = self.index(id) orelse return .miss;
            if (idx >= headers.len) return .invalid;
            return .{ .hit = headers[idx].value };
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
        return initPartsCached(allocator, method, target, path, query_string, headers, body, HeaderCache.init(headers));
    }

    pub fn initPartsCached(
        allocator: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        path: []const u8,
        query_string: []const u8,
        headers: []const HeaderPair,
        body: []const u8,
        header_cache: HeaderCache,
    ) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .target = target,
            .path = path,
            .query_string = query_string,
            .headers = headers,
            .body = body,
            .header_cache = header_cache,
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

    pub fn formData(self: *const Request) !FormData {
        const content_type = self.header("content-type") orelse return error.InvalidContentType;
        if (contentTypeMatches(content_type, "multipart/form-data")) {
            return self.multipartFormData();
        }
        if (contentTypeMatches(content_type, "application/x-www-form-urlencoded")) {
            return self.urlEncodedFormData();
        }
        return error.InvalidContentType;
    }

    pub fn multipartFormData(self: *const Request) !FormData {
        const content_type = self.header("content-type") orelse return error.InvalidContentType;
        const boundary = multipartBoundary(content_type) orelse return error.MissingMultipartBoundary;
        return parseMultipart(self.allocator, self.body, boundary);
    }

    pub fn urlEncodedFormData(self: *const Request) !FormData {
        var form = FormData.init(self.allocator);
        errdefer form.deinit();

        var pos: usize = 0;
        while (pos <= self.body.len) {
            const pair_start = pos;
            const pair_end = std.mem.indexOfScalarPos(u8, self.body, pair_start, '&') orelse self.body.len;
            pos = if (pair_end < self.body.len) pair_end + 1 else self.body.len + 1;

            const pair = self.body[pair_start..pair_end];
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                try form.fields.append(self.allocator, .{ .name = pair, .value = "" });
                continue;
            };
            try form.fields.append(self.allocator, .{
                .name = pair[0..eq],
                .value = pair[eq + 1 ..],
            });
        }

        return form;
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

fn contentTypeMatches(header: []const u8, media_type: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, header[0..end], " \t"), media_type);
}

fn multipartBoundary(content_type: []const u8) ?[]const u8 {
    var params = std.mem.splitScalar(u8, content_type, ';');
    _ = params.next();
    while (params.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "boundary")) continue;
        return unquote(std.mem.trim(u8, trimmed[eq + 1 ..], " \t"));
    }
    return null;
}

fn parseMultipart(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) !FormData {
    if (boundary.len == 0) return error.MissingMultipartBoundary;

    const marker = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(marker);
    const next_marker = try std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary});
    defer allocator.free(next_marker);

    var form = FormData.init(allocator);
    errdefer form.deinit();

    var pos: usize = 0;
    while (true) {
        if (!std.mem.startsWith(u8, body[pos..], marker)) return error.InvalidMultipartBody;
        pos += marker.len;

        if (std.mem.startsWith(u8, body[pos..], "--")) break;
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return error.InvalidMultipartBody;
        pos += 2;

        const header_end = std.mem.indexOfPos(u8, body, pos, "\r\n\r\n") orelse return error.InvalidMultipartBody;
        const headers = body[pos..header_end];
        pos = header_end + 4;

        const data_end = std.mem.indexOfPos(u8, body, pos, next_marker) orelse return error.InvalidMultipartBody;
        const data = body[pos..data_end];
        pos = data_end + 2;

        const disposition = multipartHeader(headers, "content-disposition") orelse return error.InvalidMultipartBody;
        const name = headerParam(disposition, "name") orelse return error.InvalidMultipartBody;
        const content_type = multipartHeader(headers, "content-type");

        if (headerParam(disposition, "filename")) |filename| {
            try form.files.append(allocator, .{
                .field_name = name,
                .filename = filename,
                .content_type = content_type,
                .content = data,
            });
        } else {
            try form.fields.append(allocator, .{
                .name = name,
                .value = data,
            });
        }
    }

    return form;
}

fn multipartHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn headerParam(value: []const u8, name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, value, ';');
    _ = parts.next();
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return unquote(std.mem.trim(u8, trimmed[eq + 1 ..], " \t"));
    }
    return null;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
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

test "Request parses multipart form fields and files" {
    const body =
        "--nano-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--nano-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"note.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "file bytes\r\n" ++
        "--nano-boundary--\r\n";
    const headers = [_]HeaderPair{
        .{ .name = "Content-Type", .value = "multipart/form-data; boundary=nano-boundary" },
    };
    const req = Request.init(std.testing.allocator, "POST", "/upload", &headers, body);

    var form = try req.formData();
    defer form.deinit();

    try std.testing.expectEqualStrings("hello", form.field("title").?);
    const file_value = form.file("upload").?;
    try std.testing.expectEqualStrings("upload", file_value.field_name);
    try std.testing.expectEqualStrings("note.txt", file_value.filename);
    try std.testing.expectEqualStrings("text/plain", file_value.content_type.?);
    try std.testing.expectEqualStrings("file bytes", file_value.content);
}

test "Request parses urlencoded form fields" {
    const headers = [_]HeaderPair{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };
    const req = Request.init(std.testing.allocator, "POST", "/submit", &headers, "name=rach&empty=&flag");

    var form = try req.formData();
    defer form.deinit();

    try std.testing.expectEqualStrings("rach", form.field("name").?);
    try std.testing.expectEqualStrings("", form.field("empty").?);
    try std.testing.expectEqualStrings("", form.field("flag").?);
}
