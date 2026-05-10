const std = @import("std");

const meta = @import("metadata.zig");
const openapi = @import("openapi.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const routing = @import("routing.zig");
const typed = @import("typed.zig");

pub const EventType = enum {
    startup,
    shutdown,
};

pub const EventHandler = *const fn () anyerror!void;
pub const MiddlewareFn = *const fn (*MiddlewareContext) anyerror!response.Response;

pub const MiddlewareContext = struct {
    app: *App,
    req: *request.Request,
    index: usize = 0,

    pub fn next(self: *MiddlewareContext) !response.Response {
        if (self.index >= self.app.middlewares.items.len) {
            return self.app.router.handle(self.req);
        }

        const middleware = self.app.middlewares.items[self.index];
        self.index += 1;
        return middleware(self);
    }
};

pub const AppOptions = struct {
    title: []const u8 = "NanoAPI",
    version: []const u8 = "0.1.0",
    description: []const u8 = "A Zig-native API framework",
    docs_url: ?[]const u8 = "/docs",
    redoc_url: ?[]const u8 = "/redoc",
    openapi_url: ?[]const u8 = "/openapi.json",
};

pub const App = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    version: []const u8,
    description: []const u8,
    docs_url: ?[]const u8,
    redoc_url: ?[]const u8,
    openapi_url: ?[]const u8,
    router: routing.APIRouter,
    middlewares: std.ArrayList(MiddlewareFn) = .empty,
    startup_handlers: std.ArrayList(EventHandler) = .empty,
    shutdown_handlers: std.ArrayList(EventHandler) = .empty,

    pub fn init(allocator: std.mem.Allocator, app_options: AppOptions) !App {
        const title = try allocator.dupe(u8, app_options.title);
        errdefer allocator.free(title);
        const version = try allocator.dupe(u8, app_options.version);
        errdefer allocator.free(version);
        const description = try allocator.dupe(u8, app_options.description);
        errdefer allocator.free(description);
        const docs_url = if (app_options.docs_url) |v| try allocator.dupe(u8, v) else null;
        errdefer if (docs_url) |v| allocator.free(v);
        const redoc_url = if (app_options.redoc_url) |v| try allocator.dupe(u8, v) else null;
        errdefer if (redoc_url) |v| allocator.free(v);
        const openapi_url = if (app_options.openapi_url) |v| try allocator.dupe(u8, v) else null;
        errdefer if (openapi_url) |v| allocator.free(v);

        var router = try routing.APIRouter.init(allocator, .{});
        errdefer router.deinit();

        return .{
            .allocator = allocator,
            .title = title,
            .version = version,
            .description = description,
            .docs_url = docs_url,
            .redoc_url = redoc_url,
            .openapi_url = openapi_url,
            .router = router,
        };
    }

    pub fn deinit(self: *App) void {
        self.shutdown_handlers.deinit(self.allocator);
        self.startup_handlers.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
        self.router.deinit();
        if (self.openapi_url) |v| self.allocator.free(v);
        if (self.redoc_url) |v| self.allocator.free(v);
        if (self.docs_url) |v| self.allocator.free(v);
        self.allocator.free(self.description);
        self.allocator.free(self.version);
        self.allocator.free(self.title);
        self.* = undefined;
    }

    pub fn route(
        self: *App,
        method: []const u8,
        path: []const u8,
        handler: routing.Handler,
        route_options: meta.RouteOptions,
    ) !void {
        try self.router.route(method, path, handler, route_options);
    }

    pub fn get(self: *App, path: []const u8, handler: routing.Handler, route_options: meta.RouteOptions) !void {
        try self.router.get(path, handler, route_options);
    }

    /// Register a GET route whose JSON response is fully pre-rendered at registration
    /// time. Hitting this route on the event-loop runtime skips the handler call,
    /// Response struct, Content-Length formatting, and the canUseFastJsonBytes check —
    /// the dispatcher just memcpys the cached bytes into the per-connection write
    /// buffer.
    pub fn getStaticJson(self: *App, path: []const u8, body: []const u8, route_options: meta.RouteOptions) !void {
        try self.router.getStaticJson(path, body, route_options);
    }

    pub fn getTyped(
        self: *App,
        comptime PathParams: type,
        comptime QueryParams: type,
        path: []const u8,
        comptime handler: typed.Handler(PathParams, QueryParams),
        route_options: meta.RouteOptions,
    ) !void {
        try typed.get(self, PathParams, QueryParams, path, handler, route_options);
    }

    pub fn postTypedBody(
        self: *App,
        comptime PathParams: type,
        comptime QueryParams: type,
        comptime BodyModel: type,
        path: []const u8,
        comptime handler: typed.HandlerWithBody(PathParams, QueryParams, BodyModel),
        route_options: meta.RouteOptions,
    ) !void {
        try typed.postWithBody(self, PathParams, QueryParams, BodyModel, path, handler, route_options);
    }

    pub fn post(self: *App, path: []const u8, handler: routing.Handler, route_options: meta.RouteOptions) !void {
        try self.router.post(path, handler, route_options);
    }

    pub fn put(self: *App, path: []const u8, handler: routing.Handler, route_options: meta.RouteOptions) !void {
        try self.router.put(path, handler, route_options);
    }

    pub fn delete(self: *App, path: []const u8, handler: routing.Handler, route_options: meta.RouteOptions) !void {
        try self.router.delete(path, handler, route_options);
    }

    pub fn patch(self: *App, path: []const u8, handler: routing.Handler, route_options: meta.RouteOptions) !void {
        try self.router.patch(path, handler, route_options);
    }

    pub fn head(self: *App, path: []const u8, handler: routing.Handler, route_options: meta.RouteOptions) !void {
        try self.router.head(path, handler, route_options);
    }

    pub fn options(self: *App, path: []const u8, handler: routing.Handler, route_options: meta.RouteOptions) !void {
        try self.router.options(path, handler, route_options);
    }

    pub fn includeRouter(self: *App, router: *const routing.APIRouter, include_options: routing.IncludeOptions) !void {
        try self.router.includeRouter(router, include_options);
    }

    pub fn addMiddleware(self: *App, middleware: MiddlewareFn) !void {
        try self.middlewares.append(self.allocator, middleware);
    }

    pub fn handle(self: *App, req: *request.Request) !response.Response {
        if (self.middlewares.items.len == 0) return self.router.handle(req);

        var ctx = MiddlewareContext{
            .app = self,
            .req = req,
        };
        return ctx.next();
    }

    /// Build a `server.Dispatcher` vtable wired to this App. Use this when
    /// driving the runtime via `server.serveGeneric(app.dispatcher(), ...)`
    /// rather than the `App`-bound `serve()` wrapper. This is also what
    /// non-`App` consumers (turboAPI, merjs) construct directly with their
    /// own ctx + adapter functions.
    pub fn dispatcher(self: *App) @import("server.zig").Dispatcher {
        return .{
            .ctx = @ptrCast(self),
            .handle = appHandleAdapter,
            .has_middleware = appHasMiddlewareAdapter,
            .try_static_dispatch = appTryStaticDispatchAdapter,
        };
    }

    pub fn listenAndServe(self: *App, allocator: std.mem.Allocator, server_options: @import("server.zig").Options) !void {
        try @import("server.zig").serve(self, allocator, server_options);
    }

    pub fn openapiJson(self: *const App, allocator: std.mem.Allocator) ![]u8 {
        return openapi.generate(allocator, self.title, self.version, self.description, self.router.routes());
    }

    pub fn addEventHandler(self: *App, event_type: EventType, handler: EventHandler) !void {
        switch (event_type) {
            .startup => try self.startup_handlers.append(self.allocator, handler),
            .shutdown => try self.shutdown_handlers.append(self.allocator, handler),
        }
    }

    pub fn runStartup(self: *App) !void {
        for (self.startup_handlers.items) |handler| try handler();
    }

    pub fn runShutdown(self: *App) !void {
        for (self.shutdown_handlers.items) |handler| try handler();
    }
};

fn appHandleAdapter(ctx: *anyopaque, req: *request.Request) anyerror!response.Response {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.handle(req);
}

fn appHasMiddlewareAdapter(ctx: *anyopaque) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.middlewares.items.len != 0;
}

fn appTryStaticDispatchAdapter(ctx: *anyopaque, method: []const u8, path: []const u8) ?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.router.tryStaticDispatch(method, path);
}
