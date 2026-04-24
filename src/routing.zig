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

    fn deinit(self: *RouteDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.method);
        allocator.free(self.path);
        freeRouteOptions(allocator, self.options);
        self.* = undefined;
    }
};

pub const APIRouter = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    tags: []const []const u8,
    core_router: core.Router,
    routes_list: std.ArrayList(RouteDefinition) = .empty,

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
        for (self.routes_list.items) |*route_def| route_def.deinit(self.allocator);
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

    pub fn routes(self: *const APIRouter) []const RouteDefinition {
        return self.routes_list.items;
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

        try self.routes_list.append(self.allocator, route_def);
        errdefer _ = self.routes_list.pop();

        try self.core_router.addRoute(method, full_path, key);
    }
};

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
