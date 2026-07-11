const std = @import("std");
const core = @import("turboapi-core");

const meta = @import("metadata.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const status = @import("status.zig");

pub const Handler = *const fn (*request.Request) anyerror!response.Response;

pub const RouterOptions = struct {
    prefix: []const u8 = "",
    tags: []const []const u8 = &.{},
};

pub const IncludeOptions = struct {
    prefix: []const u8 = "",
    tags: []const []const u8 = &.{},
};

pub const RouteDefinition = struct {
    key: []const u8,
    method: []const u8,
    path: []const u8,
    handler: Handler,
    options: meta.RouteOptions,
    /// Pre-rendered full HTTP response bytes (status line + headers + body).
    /// When set, the server hot path can emit these directly without invoking the handler,
    /// constructing a Response, or formatting Content-Length.
    static_response: ?[]const u8 = null,

    fn deinit(self: *RouteDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.method);
        allocator.free(self.path);
        if (self.static_response) |bytes| allocator.free(bytes);
        freeRouteOptions(allocator, self.options);
        self.* = undefined;
    }
};

const ExactRoute = struct {
    method: []const u8,
    method_slot: u3,
    path: []const u8,
    index: usize,
};

const ExactRouteKey = struct {
    method: []const u8,
    path: []const u8,
};

const ExactRouteContext = struct {
    pub fn hash(_: @This(), key: ExactRouteKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.method);
        hasher.update(&.{0});
        hasher.update(key.path);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: ExactRouteKey, b: ExactRouteKey) bool {
        return std.mem.eql(u8, a.method, b.method) and std.mem.eql(u8, a.path, b.path);
    }
};

const ExactRouteMap = std.HashMapUnmanaged(
    ExactRouteKey,
    usize,
    ExactRouteContext,
    std.hash_map.default_max_load_percentage,
);

pub const APIRouter = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    tags: []const []const u8,
    core_router: core.Router,
    routes_list: std.ArrayList(RouteDefinition) = .empty,
    exact_routes: std.ArrayList(ExactRoute) = .empty,
    exact_route_map: ExactRouteMap = .empty,
    exact_method_mask: u8 = 0,
    exact_min_path_len: [8]usize = @splat(std.math.maxInt(usize)),
    exact_max_path_len: [8]usize = @splat(0),
    root_get_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, router_options: RouterOptions) !APIRouter {
        const prefix = try allocator.dupe(u8, router_options.prefix);
        errdefer allocator.free(prefix);
        const tags = try cloneStringList(allocator, router_options.tags);
        errdefer freeStringList(allocator, tags);

        return .{
            .allocator = allocator,
            .prefix = prefix,
            .tags = tags,
            .core_router = core.Router.init(allocator),
        };
    }

    pub fn deinit(self: *APIRouter) void {
        self.exact_route_map.deinit(self.allocator);
        for (self.routes_list.items) |*route_def| route_def.deinit(self.allocator);
        self.exact_routes.deinit(self.allocator);
        self.routes_list.deinit(self.allocator);
        self.core_router.deinit();
        freeStringList(self.allocator, self.tags);
        self.allocator.free(self.prefix);
        self.* = undefined;
    }

    pub fn route(
        self: *APIRouter,
        method: []const u8,
        path: []const u8,
        handler: Handler,
        route_options: meta.RouteOptions,
    ) !void {
        try self.routeWithInheritedTags(method, path, handler, route_options, self.tags);
    }

    pub fn get(self: *APIRouter, path: []const u8, handler: Handler, route_options: meta.RouteOptions) !void {
        try self.route("GET", path, handler, route_options);
    }

    pub fn post(self: *APIRouter, path: []const u8, handler: Handler, route_options: meta.RouteOptions) !void {
        try self.route("POST", path, handler, route_options);
    }

    pub fn put(self: *APIRouter, path: []const u8, handler: Handler, route_options: meta.RouteOptions) !void {
        try self.route("PUT", path, handler, route_options);
    }

    pub fn delete(self: *APIRouter, path: []const u8, handler: Handler, route_options: meta.RouteOptions) !void {
        try self.route("DELETE", path, handler, route_options);
    }

    pub fn patch(self: *APIRouter, path: []const u8, handler: Handler, route_options: meta.RouteOptions) !void {
        try self.route("PATCH", path, handler, route_options);
    }

    pub fn head(self: *APIRouter, path: []const u8, handler: Handler, route_options: meta.RouteOptions) !void {
        try self.route("HEAD", path, handler, route_options);
    }

    pub fn options(self: *APIRouter, path: []const u8, handler: Handler, route_options: meta.RouteOptions) !void {
        try self.route("OPTIONS", path, handler, route_options);
    }

    pub fn includeRouter(self: *APIRouter, router: *const APIRouter, include_options: IncludeOptions) !void {
        for (router.routes()) |route_def| {
            const combined_path = try joinPath(self.allocator, include_options.prefix, route_def.path);
            defer self.allocator.free(combined_path);

            var inherited: std.ArrayList([]const u8) = .empty;
            defer inherited.deinit(self.allocator);
            for (self.tags) |tag| try inherited.append(self.allocator, tag);
            for (include_options.tags) |tag| try inherited.append(self.allocator, tag);

            try self.routeWithInheritedTags(
                route_def.method,
                combined_path,
                route_def.handler,
                route_def.options,
                inherited.items,
            );
        }
    }

    pub fn handle(self: *APIRouter, req: *request.Request) !response.Response {
        if (self.root_get_index) |index| {
            if (req.path.len == 1 and req.path[0] == '/' and std.mem.eql(u8, req.method, "GET")) {
                return self.routes_list.items[index].handler(req);
            }
        }

        const exact_method_mask = self.exact_method_mask;
        if (exact_method_mask != 0) {
            const exact_method_slot = methodSlot(req.method);
            if ((exact_method_mask & methodSlotMaskBit(exact_method_slot)) != 0) {
                if (self.exact_routes.items.len <= 8) {
                    if (req.path.len >= self.exact_min_path_len[exact_method_slot] and req.path.len <= self.exact_max_path_len[exact_method_slot]) {
                        for (self.exact_routes.items) |exact_route| {
                            if (exact_route.method_slot == exact_method_slot and
                                (exact_method_slot != customMethodSlot or std.mem.eql(u8, exact_route.method, req.method)) and
                                std.mem.eql(u8, exact_route.path, req.path))
                            {
                                return self.routes_list.items[exact_route.index].handler(req);
                            }
                        }
                    }
                } else {
                    if (self.exact_route_map.getContext(.{ .method = req.method, .path = req.path }, .{})) |index| {
                        return self.routes_list.items[index].handler(req);
                    }
                }
            }
        }

        var matched = self.core_router.findRoute(req.method, req.path) orelse {
            return response.jsonError(req.allocator, status.HTTP_404_NOT_FOUND, "Not Found", &.{});
        };
        defer matched.deinit();

        const index = routeIndexFromKey(matched.handler_key) orelse return error.RouteIndexCorrupt;
        if (index >= self.routes_list.items.len) return error.RouteIndexCorrupt;
        req.setPathParams(&matched.params);
        defer req.path_params = null;

        return self.routes_list.items[index].handler(req);
    }
    /// Fast static-dispatch path: if the request matches an exact route that has a
    /// pre-rendered HTTP response, return those bytes directly. Skips the handler call,
    /// Response struct construction, Content-Length formatting, and canUseFastJsonBytes
    /// dispatch. Returns null if no static route matches; the caller should fall through
    /// to the normal handle() path.
    pub fn tryStaticDispatch(self: *const APIRouter, method: []const u8, path: []const u8) ?[]const u8 {
        if (self.root_get_index) |index| {
            if (path.len == 1 and path[0] == '/' and std.mem.eql(u8, method, "GET")) {
                return self.routes_list.items[index].static_response;
            }
        }

        const exact_method_mask = self.exact_method_mask;
        if (exact_method_mask == 0) return null;
        const exact_method_slot = methodSlot(method);
        if ((exact_method_mask & methodSlotMaskBit(exact_method_slot)) == 0) return null;

        if (self.exact_routes.items.len <= 8) {
            if (path.len < self.exact_min_path_len[exact_method_slot]) return null;
            if (path.len > self.exact_max_path_len[exact_method_slot]) return null;
            for (self.exact_routes.items) |exact_route| {
                if (exact_route.method_slot == exact_method_slot and
                    (exact_method_slot != customMethodSlot or std.mem.eql(u8, exact_route.method, method)) and
                    std.mem.eql(u8, exact_route.path, path))
                {
                    return self.routes_list.items[exact_route.index].static_response;
                }
            }
            return null;
        }
        if (self.exact_route_map.getContext(.{ .method = method, .path = path }, .{})) |index| {
            return self.routes_list.items[index].static_response;
        }
        return null;
    }

    /// Register a route whose response is fully pre-rendered at registration time.
    /// `http_response_bytes` must contain the complete HTTP response (status line,
    /// headers, blank line, body) and is freed when the route is destroyed.
    pub fn routeStaticBytes(
        self: *APIRouter,
        method: []const u8,
        path: []const u8,
        http_response_bytes: []u8,
        route_options: meta.RouteOptions,
    ) !void {
        try self.routeWithInheritedTagsStatic(method, path, route_options, self.tags, http_response_bytes);
    }

    /// Convenience: pre-render a "200 OK application/json" response and register it.
    pub fn getStaticJson(
        self: *APIRouter,
        path: []const u8,
        body: []const u8,
        route_options: meta.RouteOptions,
    ) !void {
        const bytes = try renderStaticJsonResponse(self.allocator, body);
        errdefer self.allocator.free(bytes);
        try self.routeStaticBytes("GET", path, bytes, route_options);
    }

    pub fn routes(self: *const APIRouter) []const RouteDefinition {
        return self.routes_list.items;
    }

    /// Exact-route bookkeeping that runs after a route has been appended to
    /// `routes_list` and registered with `core_router`. For a root GET it records
    /// `root_get_index`; for a non-root exact path it inserts into `exact_routes`,
    /// `exact_route_map`, and updates the method mask / min/max path-length arrays.
    /// The caller MUST have reserved capacity in `exact_routes` /
    /// `exact_route_map` (via `ensureUnusedCapacity`) before appending the route
    /// when the path is a non-root exact path; this method uses the
    /// `...AssumeCapacity` variants accordingly.
    fn registerExactRoute(self: *APIRouter, owned_method: []const u8, full_path: []const u8, index: usize) void {
        const is_root_get = std.mem.eql(u8, owned_method, "GET") and std.mem.eql(u8, full_path, "/");
        if (is_root_get) {
            self.root_get_index = index;
            return;
        }
        if (!isExactPath(full_path)) return;

        const exact_method_slot = methodSlot(owned_method);
        const exact_key = ExactRouteKey{ .method = owned_method, .path = full_path };
        self.exact_routes.appendAssumeCapacity(.{
            .method = owned_method,
            .method_slot = exact_method_slot,
            .path = full_path,
            .index = index,
        });
        const gop = self.exact_route_map.getOrPutAssumeCapacityContext(exact_key, .{});
        if (!gop.found_existing) {
            gop.value_ptr.* = index;
        }
        self.exact_method_mask |= methodSlotMaskBit(exact_method_slot);
        self.exact_min_path_len[exact_method_slot] = @min(self.exact_min_path_len[exact_method_slot], full_path.len);
        self.exact_max_path_len[exact_method_slot] = @max(self.exact_max_path_len[exact_method_slot], full_path.len);
    }

    fn routeWithInheritedTags(
        self: *APIRouter,
        method: []const u8,
        path: []const u8,
        handler: Handler,
        route_options: meta.RouteOptions,
        inherited_tags: []const []const u8,
    ) !void {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;

        const full_path = try joinPath(self.allocator, self.prefix, path);
        errdefer self.allocator.free(full_path);

        const index = self.routes_list.items.len;
        const key = try routeKeyForIndex(self.allocator, index);
        errdefer self.allocator.free(key);

        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);

        const owned_options = try cloneRouteOptions(self.allocator, method, full_path, route_options, inherited_tags);
        errdefer freeRouteOptions(self.allocator, owned_options);

        const route_def = RouteDefinition{
            .key = key,
            .method = owned_method,
            .path = full_path,
            .handler = handler,
            .options = owned_options,
        };

        const is_root_get = std.mem.eql(u8, owned_method, "GET") and std.mem.eql(u8, full_path, "/");
        const is_exact_non_root = !is_root_get and isExactPath(full_path);
        if (is_exact_non_root) {
            try self.exact_routes.ensureUnusedCapacity(self.allocator, 1);
            try self.exact_route_map.ensureUnusedCapacityContext(self.allocator, 1, .{});
        }

        try self.routes_list.append(self.allocator, route_def);
        errdefer _ = self.routes_list.pop();

        try self.core_router.addRoute(method, full_path, key);

        self.registerExactRoute(owned_method, full_path, index);
    }

    fn routeWithInheritedTagsStatic(
        self: *APIRouter,
        method: []const u8,
        path: []const u8,
        route_options: meta.RouteOptions,
        inherited_tags: []const []const u8,
        http_response_bytes: []u8,
    ) !void {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;

        const full_path = try joinPath(self.allocator, self.prefix, path);
        errdefer self.allocator.free(full_path);

        const index = self.routes_list.items.len;
        const key = try routeKeyForIndex(self.allocator, index);
        errdefer self.allocator.free(key);

        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);

        const owned_options = try cloneRouteOptions(self.allocator, method, full_path, route_options, inherited_tags);
        errdefer freeRouteOptions(self.allocator, owned_options);

        const route_def = RouteDefinition{
            .key = key,
            .method = owned_method,
            .path = full_path,
            .handler = staticPlaceholderHandler,
            .options = owned_options,
            .static_response = http_response_bytes,
        };

        const is_root_get = std.mem.eql(u8, owned_method, "GET") and std.mem.eql(u8, full_path, "/");
        const is_exact_non_root = !is_root_get and isExactPath(full_path);
        if (is_exact_non_root) {
            try self.exact_routes.ensureUnusedCapacity(self.allocator, 1);
            try self.exact_route_map.ensureUnusedCapacityContext(self.allocator, 1, .{});
        }

        try self.routes_list.append(self.allocator, route_def);
        errdefer _ = self.routes_list.pop();

        try self.core_router.addRoute(method, full_path, key);

        self.registerExactRoute(owned_method, full_path, index);
    }
};

/// Fallback handler for static routes that gets invoked only on the slow paths
/// (custom middleware, includeRouter remap, parameterised paths). It re-emits the
/// pre-rendered body so behaviour stays identical even if the static dispatch
/// shortcut was bypassed.
fn staticPlaceholderHandler(req: *request.Request) anyerror!response.Response {
    return response.jsonError(req.allocator, status.HTTP_500_INTERNAL_SERVER_ERROR, "Static route invoked through dynamic dispatch", &.{});
}

/// Build a fully formed "HTTP/1.1 200 OK\r\nContent-Length: N\r\nContent-Type: application/json\r\n\r\n<body>"
/// response. Returned slice is owned by the caller (and ultimately the route).
fn renderStaticJsonResponse(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\n\r\n{s}",
        .{ body.len, body },
    );
}
fn isExactPath(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, "{*") == null;
}

fn methodSlotMaskBit(slot: u3) u8 {
    return @as(u8, 1) << slot;
}

const customMethodSlot: u3 = 7;

fn methodSlot(method: []const u8) u3 {
    if (method.len < 3) return customMethodSlot;
    return switch (method[0]) {
        'G' => if (method.len == 3 and method[1] == 'E' and method[2] == 'T') 0 else customMethodSlot,
        'P' => switch (method.len) {
            3 => if (method[1] == 'U' and method[2] == 'T') 2 else customMethodSlot,
            4 => if (method[1] == 'O' and method[2] == 'S' and method[3] == 'T') 1 else customMethodSlot,
            5 => if (method[1] == 'A' and method[2] == 'T' and method[3] == 'C' and method[4] == 'H') 4 else customMethodSlot,
            else => customMethodSlot,
        },
        'D' => if (method.len == 6 and std.mem.eql(u8, method, "DELETE")) 3 else customMethodSlot,
        'H' => if (method.len == 4 and std.mem.eql(u8, method, "HEAD")) 5 else customMethodSlot,
        'O' => if (method.len == 7 and std.mem.eql(u8, method, "OPTIONS")) 6 else customMethodSlot,
        else => customMethodSlot,
    };
}

fn routeKeyForIndex(allocator: std.mem.Allocator, index: usize) ![]u8 {
    const key = try allocator.alloc(u8, @sizeOf(usize));
    std.mem.writeInt(usize, key[0..@sizeOf(usize)], index, .little);
    return key;
}

fn routeIndexFromKey(key: []const u8) ?usize {
    if (key.len != @sizeOf(usize)) return null;
    return std.mem.bytesToValue(usize, key[0..@sizeOf(usize)]);
}

fn cloneRouteOptions(
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    options: meta.RouteOptions,
    inherited_tags: []const []const u8,
) !meta.RouteOptions {
    const name = if (options.name) |n|
        try allocator.dupe(u8, n)
    else
        try defaultRouteName(allocator, method, path);
    errdefer allocator.free(name);

    return .{
        .name = name,
        .response_model = try dupeOptional(allocator, options.response_model),
        .tags = try mergeTags(allocator, inherited_tags, options.tags),
        .summary = try dupeOptional(allocator, options.summary),
        .description = try dupeOptional(allocator, options.description),
        .parameters = try cloneParameters(allocator, options.parameters),
        .status_code = options.status_code,
    };
}

fn freeRouteOptions(allocator: std.mem.Allocator, options: meta.RouteOptions) void {
    if (options.name) |v| allocator.free(v);
    if (options.response_model) |v| allocator.free(v);
    freeStringList(allocator, options.tags);
    if (options.summary) |v| allocator.free(v);
    if (options.description) |v| allocator.free(v);
    freeParameters(allocator, options.parameters);
}

fn cloneParameters(allocator: std.mem.Allocator, params: []const meta.Parameter) ![]const meta.Parameter {
    const out = try allocator.alloc(meta.Parameter, params.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |p| freeParameter(allocator, p);
    }

    for (params, 0..) |p, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, p.name),
            .location = p.location,
            .schema_type = p.schema_type,
            .required = p.required,
            .default = try dupeOptional(allocator, p.default),
            .alias = try dupeOptional(allocator, p.alias),
            .title = try dupeOptional(allocator, p.title),
            .description = try dupeOptional(allocator, p.description),
            .min_length = p.min_length,
            .max_length = p.max_length,
            .gt = p.gt,
            .ge = p.ge,
            .lt = p.lt,
            .le = p.le,
        };
        initialized += 1;
    }

    return out;
}

fn freeParameters(allocator: std.mem.Allocator, params: []const meta.Parameter) void {
    for (params) |p| freeParameter(allocator, p);
    allocator.free(params);
}

fn freeParameter(allocator: std.mem.Allocator, p: meta.Parameter) void {
    allocator.free(p.name);
    if (p.default) |v| allocator.free(v);
    if (p.alias) |v| allocator.free(v);
    if (p.title) |v| allocator.free(v);
    if (p.description) |v| allocator.free(v);
}

fn defaultRouteName(allocator: std.mem.Allocator, method: []const u8, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (method) |ch| try out.append(allocator, std.ascii.toLower(ch));
    try out.append(allocator, '_');
    for (path) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9' => try out.append(allocator, std.ascii.toLower(ch)),
            else => {
                if (out.items.len == 0 or out.items[out.items.len - 1] != '_') {
                    try out.append(allocator, '_');
                }
            },
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        out.items.len -= 1;
    }
    return out.toOwnedSlice(allocator);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |v| allocator.free(v);
    }

    for (values, 0..) |v, i| {
        out[i] = try allocator.dupe(u8, v);
        initialized += 1;
    }
    return out;
}

fn mergeTags(
    allocator: std.mem.Allocator,
    inherited: []const []const u8,
    local: []const []const u8,
) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, inherited.len + local.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |v| allocator.free(v);
    }

    for (inherited) |v| {
        out[initialized] = try allocator.dupe(u8, v);
        initialized += 1;
    }
    for (local) |v| {
        out[initialized] = try allocator.dupe(u8, v);
        initialized += 1;
    }
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |v| allocator.free(v);
    allocator.free(values);
}

fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, path: []const u8) ![]u8 {
    if (prefix.len == 0) return try allocator.dupe(u8, path);
    if (path.len == 0) return try allocator.dupe(u8, prefix);
    if (std.mem.endsWith(u8, prefix, "/") and std.mem.startsWith(u8, path, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, path[1..] });
    }
    if (!std.mem.endsWith(u8, prefix, "/") and !std.mem.startsWith(u8, path, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, path });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, path });
}

fn propfindHandler(req: *request.Request) anyerror!response.Response {
    return response.Response.fromStaticBody(req.allocator, "propfind", .{ .media_type = "text/plain" });
}

fn reportHandler(req: *request.Request) anyerror!response.Response {
    return response.Response.fromStaticBody(req.allocator, "report", .{ .media_type = "text/plain" });
}

test "APIRouter exact static dispatch keeps custom methods distinct" {
    const allocator = std.testing.allocator;
    var router = try APIRouter.init(allocator, .{});
    defer router.deinit();

    try router.route("PROPFIND", "/resource", propfindHandler, .{});
    try router.route("REPORT", "/resource", reportHandler, .{});

    var propfind_req = request.Request.init(allocator, "PROPFIND", "/resource", &.{}, "");
    var propfind_res = try router.handle(&propfind_req);
    defer propfind_res.deinit();
    try std.testing.expectEqualStrings("propfind", propfind_res.body);

    var report_req = request.Request.init(allocator, "REPORT", "/resource", &.{}, "");
    var report_res = try router.handle(&report_req);
    defer report_res.deinit();
    try std.testing.expectEqualStrings("report", report_res.body);
}
