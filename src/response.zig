const std = @import("std");
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

pub const Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16 = status.HTTP_200_OK,
    media_type: ?[]const u8 = null,
    media_type_owned: bool = false,
    body: []const u8 = &.{},
    body_owned: bool = false,
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

        const media_type = if (options.media_type) |m| try allocator.dupe(u8, m) else null;
        var media_owned = true;
        errdefer if (media_owned) {
            if (media_type) |m| allocator.free(m);
        };

        var res = Response{
            .allocator = allocator,
            .status_code = options.status_code,
            .media_type = media_type,
            .media_type_owned = media_type != null,
            .body = body,
            .body_owned = true,
        };
        body_owned = false;
        media_owned = false;
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
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat_info = try file.stat();
        const size: usize = @intCast(stat_info.size);
        const body = try allocator.alloc(u8, size);
        errdefer allocator.free(body);
        const read = try file.readAll(body);
        if (read != size) return error.UnexpectedEndOfFile;

        var opts = options;
        if (opts.media_type == null) opts.media_type = guessMediaType(path);
        var res = try Response.fromOwnedBody(allocator, body, opts);
        errdefer res.deinit();

        const length = try std.fmt.allocPrint(allocator, "{d}", .{read});
        defer allocator.free(length);
        try res.setHeader("content-length", length);

        if (filename) |name| {
            const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{name});
            defer allocator.free(disposition);
            try res.setHeader("content-disposition", disposition);
        }

        return res;
    }
};

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
