const std = @import("std");

const app_mod = @import("app.zig");
const request = @import("request.zig");
const response = @import("response.zig");

pub const Invocation = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    query_string: []const u8 = "",
    headers: []const request.HeaderPair = &.{},
    body: []const u8 = "",

    pub fn init(
        method: []const u8,
        target: []const u8,
        headers: []const request.HeaderPair,
        body: []const u8,
    ) Invocation {
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        return .{
            .method = method,
            .target = target,
            .path = if (query_start) |idx| target[0..idx] else target,
            .query_string = if (query_start) |idx| target[idx + 1 ..] else "",
            .headers = headers,
            .body = body,
        };
    }
};

pub const ServerlessResponse = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    headers: []response.Header = &.{},
    body: []const u8 = "",
    is_base64_encoded: bool = false,

    pub fn deinit(self: *ServerlessResponse) void {
        for (self.headers) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn handle(app: *app_mod.App, allocator: std.mem.Allocator, invocation: Invocation) !response.Response {
    var req = request.Request.initParts(
        allocator,
        invocation.method,
        invocation.target,
        invocation.path,
        invocation.query_string,
        invocation.headers,
        invocation.body,
    );
    return app.handle(&req);
}

pub fn handleBytes(app: *app_mod.App, allocator: std.mem.Allocator, invocation: Invocation) !ServerlessResponse {
    var res = try handle(app, allocator, invocation);
    defer res.deinit();
    return collectBytes(allocator, &res);
}

pub fn collectBytes(allocator: std.mem.Allocator, res: *const response.Response) !ServerlessResponse {
    if (res.body_kind != .bytes) return error.UnsupportedServerlessBody;

    var out = ServerlessResponse{
        .allocator = allocator,
        .status_code = res.status_code,
    };
    errdefer out.deinit();

    const include_media_type = res.media_type != null and !hasHeader(res.headers.items, "content-type");
    const header_count = res.headers.items.len + @intFromBool(include_media_type);
    var headers = try allocator.alloc(response.Header, header_count);

    var initialized: usize = 0;
    var headers_committed = false;
    errdefer {
        if (!headers_committed) {
            for (headers[0..initialized]) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(headers);
        }
    }

    for (res.headers.items) |header| {
        {
            const owned_name = try allocator.dupe(u8, header.name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, header.value);
            errdefer allocator.free(owned_value);
            headers[initialized] = .{
                .name = owned_name,
                .value = owned_value,
            };
        }
        initialized += 1;
    }
    if (include_media_type) {
        {
            const owned_name = try allocator.dupe(u8, "content-type");
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, res.media_type.?);
            errdefer allocator.free(owned_value);
            headers[initialized] = .{
                .name = owned_name,
                .value = owned_value,
            };
        }
        initialized += 1;
    }

    out.headers = headers;
    headers_committed = true;

    errdefer {
        for (out.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(out.headers);
        out.headers = &.{};
    }

    out.body = try allocator.dupe(u8, res.body);
    return out;
}

fn hasHeader(headers: []const response.Header, name: []const u8) bool {
    for (headers) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
    }
    return false;
}

pub const aws_http_v2 = struct {
    pub const ParsedInvocation = struct {
        allocator: std.mem.Allocator,
        parsed: std.json.Parsed(std.json.Value),
        invocation: Invocation,
        headers: []request.HeaderPair = &.{},
        target_owned: bool = false,
        body_owned: bool = false,

        pub fn deinit(self: *ParsedInvocation) void {
            if (self.headers.len != 0) self.allocator.free(self.headers);
            if (self.target_owned) self.allocator.free(self.invocation.target);
            if (self.body_owned) self.allocator.free(self.invocation.body);
            self.parsed.deinit();
            self.* = undefined;
        }
    };

    pub fn parseInvocation(allocator: std.mem.Allocator, event_json: []const u8) !ParsedInvocation {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, event_json, .{});
        errdefer parsed.deinit();

        const root_object = switch (parsed.value) {
            .object => |*object| object,
            else => return error.InvalidAwsHttpV2Event,
        };

        const raw_path = stringField(root_object, "rawPath") orelse blk: {
            if (root_object.get("requestContext")) |request_context| {
                const request_context_object = asObject(request_context) orelse break :blk null;
                if (request_context_object.get("http")) |http| {
                    const http_object = asObject(http) orelse break :blk null;
                    break :blk stringField(http_object, "path");
                }
            }
            break :blk null;
        } orelse return error.InvalidAwsHttpV2Event;

        const raw_query_string = stringField(root_object, "rawQueryString") orelse "";
        const method = blk: {
            if (root_object.get("requestContext")) |request_context| {
                const request_context_object = asObject(request_context) orelse break :blk null;
                if (request_context_object.get("http")) |http| {
                    const http_object = asObject(http) orelse break :blk null;
                    break :blk stringField(http_object, "method");
                }
            }
            break :blk null;
        } orelse return error.InvalidAwsHttpV2Event;

        const headers = try parseHeaders(allocator, root_object);
        errdefer allocator.free(headers);

        const target = if (raw_query_string.len == 0)
            raw_path
        else
            try std.fmt.allocPrint(allocator, "{s}?{s}", .{ raw_path, raw_query_string });
        errdefer if (raw_query_string.len != 0) allocator.free(target);

        const body_raw = stringField(root_object, "body") orelse "";
        const is_base64 = boolField(root_object, "isBase64Encoded") orelse false;
        const body = if (is_base64)
            try decodeBase64(allocator, body_raw)
        else
            body_raw;
        errdefer if (is_base64) allocator.free(body);

        return .{
            .allocator = allocator,
            .parsed = parsed,
            .invocation = .{
                .method = method,
                .target = target,
                .path = raw_path,
                .query_string = raw_query_string,
                .headers = headers,
                .body = body,
            },
            .headers = headers,
            .target_owned = raw_query_string.len != 0,
            .body_owned = is_base64,
        };
    }

    pub fn handle(app: *app_mod.App, allocator: std.mem.Allocator, event_json: []const u8) !response.Response {
        var parsed = try parseInvocation(allocator, event_json);
        defer parsed.deinit();
        return @import("serverless.zig").handle(app, allocator, parsed.invocation);
    }

    pub fn handleBytes(app: *app_mod.App, allocator: std.mem.Allocator, event_json: []const u8) !ServerlessResponse {
        var parsed = try parseInvocation(allocator, event_json);
        defer parsed.deinit();
        return @import("serverless.zig").handleBytes(app, allocator, parsed.invocation);
    }

    pub fn handleJson(app: *app_mod.App, allocator: std.mem.Allocator, event_json: []const u8) ![]u8 {
        var out = try @This().handleBytes(app, allocator, event_json);
        defer out.deinit();
        return responseJson(allocator, &out);
    }

    pub fn responseJson(allocator: std.mem.Allocator, res: *const ServerlessResponse) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const cookie_count = countHeaders(res.headers, "set-cookie");
        try out.print(allocator, "{{\"statusCode\":{d},\"headers\":{{", .{res.status_code});
        var first_header = true;
        for (res.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
            if (!first_header) try out.append(allocator, ',');
            first_header = false;
            try appendJsonString(&out, allocator, header.name);
            try out.append(allocator, ':');
            try appendJsonString(&out, allocator, header.value);
        }
        try out.append(allocator, '}');

        if (cookie_count > 0) {
            try out.appendSlice(allocator, ",\"cookies\":[");
            var seen: usize = 0;
            for (res.headers) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
                if (seen > 0) try out.append(allocator, ',');
                seen += 1;
                try appendJsonString(&out, allocator, header.value);
            }
            try out.append(allocator, ']');
        }

        try out.appendSlice(allocator, ",\"body\":");
        if (res.is_base64_encoded) {
            try appendJsonString(&out, allocator, res.body);
        } else {
            try appendJsonString(&out, allocator, res.body);
        }
        try out.appendSlice(allocator, ",\"isBase64Encoded\":");
        try out.appendSlice(allocator, if (res.is_base64_encoded) "true" else "false");
        try out.append(allocator, '}');
        return out.toOwnedSlice(allocator);
    }

    fn parseHeaders(allocator: std.mem.Allocator, root_object: *const std.json.ObjectMap) ![]request.HeaderPair {
        const headers_value = root_object.get("headers") orelse return &.{};
        const headers_object = asObject(headers_value) orelse return error.InvalidAwsHttpV2Event;

        var header_count: usize = 0;
        var count_it = headers_object.iterator();
        while (count_it.next()) |entry| {
            if (entry.value_ptr.* == .string) header_count += 1;
        }
        if (header_count == 0) return &.{};

        var headers = try allocator.alloc(request.HeaderPair, header_count);
        errdefer allocator.free(headers);

        var i: usize = 0;
        var it = headers_object.iterator();
        while (it.next()) |entry| {
            const value = switch (entry.value_ptr.*) {
                .string => |value| value,
                else => continue,
            };
            headers[i] = .{
                .name = entry.key_ptr.*,
                .value = value,
            };
            i += 1;
        }
        return headers[0..i];
    }

    fn decodeBase64(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(value);
        const out = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(out);
        try std.base64.standard.Decoder.decode(out, value);
        return out;
    }

    fn asObject(value: std.json.Value) ?*const std.json.ObjectMap {
        return switch (value) {
            .object => |*object| object,
            else => null,
        };
    }

    fn stringField(object: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
        const value = object.get(name) orelse return null;
        return switch (value) {
            .string => |string| string,
            else => null,
        };
    }

    fn boolField(object: *const std.json.ObjectMap, name: []const u8) ?bool {
        const value = object.get(name) orelse return null;
        return switch (value) {
            .bool => |boolean| boolean,
            else => null,
        };
    }
};

fn countHeaders(headers: []const response.Header, name: []const u8) usize {
    var count: usize = 0;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) count += 1;
    }
    return count;
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

fn root(req: *request.Request) anyerror!response.Response {
    return response.JSONResponse.static(req.allocator, "{\"ok\":true}", .{});
}

fn cookieHandler(req: *request.Request) anyerror!response.Response {
    var res = try response.JSONResponse.static(req.allocator, "{\"ok\":true}", .{});
    errdefer res.deinit();
    try res.setHeader("set-cookie", "session=abc; Path=/; HttpOnly");
    return res;
}

test "serverless invocation runs through app middleware and router" {
    const allocator = std.testing.allocator;
    var app = try app_mod.App.init(allocator, .{});
    defer app.deinit();

    const Middleware = struct {
        fn addHeader(ctx: *app_mod.MiddlewareContext) !response.Response {
            var res = try ctx.next();
            errdefer res.deinit();
            try res.setHeader("x-serverless", "1");
            return res;
        }
    };

    try app.addMiddleware(Middleware.addHeader);
    try app.get("/", root, .{});

    var out = try handleBytes(&app, allocator, Invocation.init("GET", "/?debug=true", &.{}, ""));
    defer out.deinit();

    try std.testing.expectEqual(@as(u16, 200), out.status_code);
    try std.testing.expectEqualStrings("{\"ok\":true}", out.body);
    try std.testing.expectEqualStrings("application/json", lookupHeader(&out, "content-type").?);
    try std.testing.expectEqualStrings("1", lookupHeader(&out, "x-serverless").?);
}

fn lookupHeader(res: *const ServerlessResponse, name: []const u8) ?[]const u8 {
    for (res.headers) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
    }
    return null;
}

test "AWS HTTP API v2 adapter parses event and serializes response JSON" {
    const allocator = std.testing.allocator;
    var app = try app_mod.App.init(allocator, .{});
    defer app.deinit();

    try app.get("/", root, .{});

    const event_json =
        \\{
        \\  "version": "2.0",
        \\  "routeKey": "GET /",
        \\  "rawPath": "/",
        \\  "rawQueryString": "debug=true",
        \\  "headers": {
        \\    "accept": "application/json",
        \\    "host": "example.lambda-url.us-east-1.on.aws"
        \\  },
        \\  "requestContext": {
        \\    "http": {
        \\      "method": "GET",
        \\      "path": "/"
        \\    }
        \\  },
        \\  "isBase64Encoded": false
        \\}
    ;

    var out = try aws_http_v2.handleBytes(&app, allocator, event_json);
    defer out.deinit();

    try std.testing.expectEqual(@as(u16, 200), out.status_code);
    try std.testing.expectEqualStrings("{\"ok\":true}", out.body);
    try std.testing.expectEqualStrings("application/json", lookupHeader(&out, "content-type").?);

    const json = try aws_http_v2.responseJson(allocator, &out);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"statusCode\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"body\":\"{\\\"ok\\\":true}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isBase64Encoded\":false") != null);
}

test "AWS HTTP API v2 adapter decodes base64 request bodies" {
    const allocator = std.testing.allocator;

    const event_json =
        \\{
        \\  "version": "2.0",
        \\  "rawPath": "/upload",
        \\  "rawQueryString": "",
        \\  "headers": {"content-type": "text/plain"},
        \\  "requestContext": {"http": {"method": "POST", "path": "/upload"}},
        \\  "body": "aGVsbG8=",
        \\  "isBase64Encoded": true
        \\}
    ;

    var parsed = try aws_http_v2.parseInvocation(allocator, event_json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("POST", parsed.invocation.method);
    try std.testing.expectEqualStrings("/upload", parsed.invocation.path);
    try std.testing.expectEqualStrings("hello", parsed.invocation.body);
    try std.testing.expectEqualStrings("text/plain", parsed.invocation.headers[0].value);
}

test "AWS HTTP API v2 response JSON emits cookies array" {
    const allocator = std.testing.allocator;
    var app = try app_mod.App.init(allocator, .{});
    defer app.deinit();

    try app.get("/cookie", cookieHandler, .{});

    const event_json =
        \\{
        \\  "version": "2.0",
        \\  "rawPath": "/cookie",
        \\  "rawQueryString": "",
        \\  "headers": {},
        \\  "requestContext": {"http": {"method": "GET", "path": "/cookie"}},
        \\  "isBase64Encoded": false
        \\}
    ;

    const json = try aws_http_v2.handleJson(&app, allocator, event_json);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"cookies\":[\"session=abc; Path=/; HttpOnly\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"set-cookie\"") == null);
}
