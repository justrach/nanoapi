const std = @import("std");

pub const core = @import("turboapi-core");

pub const app = @import("app.zig");
pub const background = @import("background.zig");
pub const metadata = @import("metadata.zig");
pub const openapi = @import("openapi.zig");
pub const params = @import("params.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const routing = @import("routing.zig");
pub const security = @import("security.zig");
pub const server = @import("server.zig");
pub const status = @import("status.zig");
pub const typed = @import("typed.zig");
pub const validation = @import("validation.zig");

pub const App = app.App;
pub const NanoAPI = app.App;
pub const APIRouter = routing.APIRouter;
pub const Router = routing.APIRouter;

pub const Request = request.Request;
pub const HeaderPair = request.HeaderPair;

pub const Response = response.Response;
pub const JSONResponse = response.JSONResponse;
pub const HTMLResponse = response.HTMLResponse;
pub const PlainTextResponse = response.PlainTextResponse;
pub const RedirectResponse = response.RedirectResponse;
pub const FileResponse = response.FileResponse;
pub const StreamingResponse = response.StreamingResponse;
pub const EventSourceResponse = response.EventSourceResponse;
pub const StreamContext = response.StreamContext;
pub const SseWriter = response.SseWriter;

pub const Path = params.Path;
pub const Query = params.Query;
pub const Header = params.Header;
pub const Cookie = params.Cookie;
pub const Body = params.Body;
pub const Form = params.Form;
pub const File = params.File;
pub const SchemaType = metadata.SchemaType;
pub const Parameter = metadata.Parameter;
pub const RouteOptions = metadata.RouteOptions;

pub const BackgroundTasks = background.BackgroundTasks;
pub const ValidationErrors = validation.ValidationErrors;
pub const ValidationResult = validation.ValidationResult;
pub const BoundedInt = validation.BoundedInt;
pub const BoundedString = validation.BoundedString;
pub const Email = validation.Email;

pub const HTTPException = security.HTTPException;
pub const RequestValidationError = security.RequestValidationError;
pub const WebSocketException = security.WebSocketException;
pub const Depends = security.Depends;
pub const Security = security.Security;
pub const SecurityScopes = security.SecurityScopes;
pub const HTTPBasic = security.HTTPBasic;
pub const HTTPBasicCredentials = security.HTTPBasicCredentials;
pub const HTTPBearer = security.HTTPBearer;
pub const HTTPAuthorizationCredentials = security.HTTPAuthorizationCredentials;
pub const OAuth2PasswordBearer = security.OAuth2PasswordBearer;
pub const OAuth2AuthorizationCodeBearer = security.OAuth2AuthorizationCodeBearer;
pub const APIKeyHeader = security.APIKeyHeader;
pub const APIKeyQuery = security.APIKeyQuery;
pub const APIKeyCookie = security.APIKeyCookie;

fn rootHandler(req: *Request) anyerror!Response {
    return JSONResponse.init(req.allocator, "{\"message\":\"Hello\"}", .{});
}

fn userHandler(req: *Request) anyerror!Response {
    const user_id = req.pathInt("user_id") orelse return response.jsonError(
        req.allocator,
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "invalid user_id",
        &.{},
    );
    const verbose = req.queryBool("verbose") orelse false;
    const body = try std.fmt.allocPrint(
        req.allocator,
        "{{\"user_id\":{d},\"verbose\":{s}}}",
        .{ user_id, if (verbose) "true" else "false" },
    );
    return response.Response.fromOwnedBody(req.allocator, body, .{ .media_type = "application/json" });
}

test "NanoAPI registers and dispatches routes through turboapi-core" {
    const allocator = std.testing.allocator;
    var api = try NanoAPI.init(allocator, .{ .title = "TestApp", .version = "1.0.0" });
    defer api.deinit();

    try api.get("/", rootHandler, .{});

    const parameters = [_]Parameter{
        Path("user_id", .integer, .{}),
        Query("verbose", .boolean, .{ .required = false, .default = "false" }),
    };
    try api.get("/users/{user_id}", userHandler, .{
        .tags = &.{"users"},
        .summary = "Get User",
        .parameters = &parameters,
    });

    var req = Request.init(allocator, "GET", "/users/42?verbose=true", &.{}, "");
    var resp = try api.handle(&req);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("application/json", resp.header("content-type").?);
    try std.testing.expectEqualStrings("{\"user_id\":42,\"verbose\":true}", resp.body);
}

test "APIRouter includeRouter applies prefixes" {
    const allocator = std.testing.allocator;
    var api = try NanoAPI.init(allocator, .{});
    defer api.deinit();

    var router = try APIRouter.init(allocator, .{ .prefix = "/v1", .tags = &.{"v1"} });
    defer router.deinit();
    try router.get("/health", rootHandler, .{});

    try api.includeRouter(&router, .{ .prefix = "/api", .tags = &.{"api"} });

    var req = Request.init(allocator, "GET", "/api/v1/health", &.{}, "");
    var resp = try api.handle(&req);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("{\"message\":\"Hello\"}", resp.body);
}

test "OpenAPI generation exposes FastAPI-style metadata" {
    const allocator = std.testing.allocator;
    var api = try NanoAPI.init(allocator, .{ .title = "OpenAPITest", .version = "2.0.0" });
    defer api.deinit();

    const parameters = [_]Parameter{
        Path("user_id", .integer, .{}),
        Query("q", .string, .{ .required = false }),
    };
    try api.get("/users/{user_id}", userHandler, .{
        .name = "get_user",
        .tags = &.{"users"},
        .parameters = &parameters,
    });

    const json = try api.openapiJson(allocator);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"openapi\":\"3.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"title\":\"OpenAPITest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"/users/{user_id}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"operationId\":\"get_user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"in\":\"path\"") != null);
}

test "responses and security helpers mirror FastAPI names" {
    const allocator = std.testing.allocator;

    var redirect = try RedirectResponse.init(allocator, "/new-path", .{});
    defer redirect.deinit();
    try std.testing.expectEqual(@as(u16, status.HTTP_307_TEMPORARY_REDIRECT), redirect.status_code);
    try std.testing.expectEqualStrings("/new-path", redirect.header("location").?);

    try redirect.setCookie("session", "abc123", .{ .httponly = true });
    try std.testing.expect(std.mem.indexOf(u8, redirect.header("set-cookie").?, "HttpOnly") != null);

    const headers = [_]HeaderPair{
        .{ .name = "Authorization", .value = "Bearer token-123" },
        .{ .name = "Cookie", .value = "session=abc123" },
    };
    var req = Request.init(allocator, "GET", "/protected", &headers, "");
    const bearer = OAuth2PasswordBearer.init("/token");
    try std.testing.expectEqualStrings("token-123", bearer.extract(&req).?);

    const api_key = APIKeyCookie.init("session");
    try std.testing.expectEqualStrings("abc123", api_key.extract(&req).?);
}

test "typed routes parse path and query structs" {
    const allocator = std.testing.allocator;
    var api = try NanoAPI.init(allocator, .{});
    defer api.deinit();

    const PathParams = struct {
        user_id: i64,
    };
    const QueryParams = struct {
        verbose: bool = false,
    };
    const Handler = struct {
        fn getUser(ctx: typed.Context(PathParams, QueryParams)) anyerror!Response {
            const body = try std.fmt.allocPrint(
                ctx.raw.allocator,
                "{{\"user_id\":{d},\"verbose\":{s}}}",
                .{ ctx.path.user_id, if (ctx.query.verbose) "true" else "false" },
            );
            return response.Response.fromOwnedBody(ctx.raw.allocator, body, .{ .media_type = "application/json" });
        }
    };

    try api.getTyped(PathParams, QueryParams, "/typed/{user_id}", Handler.getUser, .{});

    var req = Request.init(allocator, "GET", "/typed/42?verbose=true", &.{}, "");
    var resp = try api.handle(&req);
    defer resp.deinit();

    try std.testing.expectEqualStrings("{\"user_id\":42,\"verbose\":true}", resp.body);

    const route = api.router.routes()[0];
    try std.testing.expectEqual(@as(usize, 2), route.options.parameters.len);
    try std.testing.expectEqualStrings("user_id", route.options.parameters[0].name);
    try std.testing.expectEqual(metadata.Location.path, route.options.parameters[0].location);
    try std.testing.expectEqual(metadata.SchemaType.integer, route.options.parameters[0].schema_type);
    try std.testing.expectEqualStrings("verbose", route.options.parameters[1].name);
    try std.testing.expect(!route.options.parameters[1].required);
}

test "typed routes return DHI-backed validation errors" {
    const allocator = std.testing.allocator;
    var api = try NanoAPI.init(allocator, .{});
    defer api.deinit();

    const QueryParams = struct {
        email: []const u8,
    };
    const Handler = struct {
        fn get(ctx: typed.Context(typed.Empty, QueryParams)) anyerror!Response {
            _ = ctx;
            return response.JSONResponse.static(std.testing.allocator, "{\"ok\":true}", .{});
        }
    };

    try api.getTyped(typed.Empty, QueryParams, "/validate", Handler.get, .{});

    var req = Request.init(allocator, "GET", "/validate?email=invalid", &.{}, "");
    var resp = try api.handle(&req);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, status.HTTP_422_UNPROCESSABLE_ENTITY), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "ValidationFailed") != null);
}

test {
    _ = core;
    _ = app;
    _ = background;
    _ = metadata;
    _ = openapi;
    _ = params;
    _ = request;
    _ = response;
    _ = routing;
    _ = security;
    _ = server;
    _ = status;
    _ = typed;
    _ = validation;
}
