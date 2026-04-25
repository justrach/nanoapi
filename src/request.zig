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
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn cookie(self: *const Request, name: []const u8) ?[]const u8 {
        const cookie_header = self.header("cookie") orelse return null;
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
};
