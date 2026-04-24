const std = @import("std");

const request = @import("request.zig");
const response = @import("response.zig");
const status = @import("status.zig");

pub const HTTPException = struct {
    status_code: u16,
    detail: []const u8 = "",
    headers: []const response.Header = &.{},

    pub fn toResponse(self: HTTPException, allocator: std.mem.Allocator) !response.Response {
        return response.jsonError(allocator, self.status_code, self.detail, self.headers);
    }
};

pub const RequestValidationError = struct {
    detail: []const u8,
};

pub const WebSocketException = struct {
    code: u16 = 1000,
    reason: ?[]const u8 = null,
};

pub const Depends = struct {
    dependency: ?*const anyopaque = null,
    use_cache: bool = true,
};

pub const Security = Depends;

pub const SecurityScopes = struct {
    scopes: []const []const u8 = &.{},
};

pub const HTTPBasicCredentials = struct {
    username: []const u8,
    password: []const u8,
};

pub const HTTPAuthorizationCredentials = struct {
    scheme: []const u8,
    credentials: []const u8,
};

pub const OAuth2PasswordBearer = struct {
    token_url: []const u8,
    scheme_name: ?[]const u8 = null,
    auto_error: bool = true,

    pub fn init(token_url: []const u8) OAuth2PasswordBearer {
        return .{ .token_url = token_url };
    }

    pub fn extract(self: OAuth2PasswordBearer, req: *const request.Request) ?[]const u8 {
        _ = self;
        return bearerToken(req);
    }
};

pub const OAuth2AuthorizationCodeBearer = struct {
    authorization_url: []const u8,
    token_url: []const u8,
    refresh_url: ?[]const u8 = null,
    scheme_name: ?[]const u8 = null,
    auto_error: bool = true,

    pub fn init(authorization_url: []const u8, token_url: []const u8) OAuth2AuthorizationCodeBearer {
        return .{ .authorization_url = authorization_url, .token_url = token_url };
    }

    pub fn extract(self: OAuth2AuthorizationCodeBearer, req: *const request.Request) ?[]const u8 {
        _ = self;
        return bearerToken(req);
    }
};

pub const HTTPBearer = struct {
    scheme_name: ?[]const u8 = null,
    auto_error: bool = true,

    pub fn init() HTTPBearer {
        return .{};
    }

    pub fn extract(self: HTTPBearer, req: *const request.Request) ?HTTPAuthorizationCredentials {
        _ = self;
        const authorization = req.header("authorization") orelse return null;
        const split = std.mem.indexOfScalar(u8, authorization, ' ') orelse return null;
        const scheme = authorization[0..split];
        if (!std.ascii.eqlIgnoreCase(scheme, "bearer")) return null;
        return .{ .scheme = scheme, .credentials = authorization[split + 1 ..] };
    }
};

pub const HTTPBasic = struct {
    scheme_name: ?[]const u8 = null,
    realm: ?[]const u8 = null,
    auto_error: bool = true,

    pub fn init() HTTPBasic {
        return .{};
    }
};

pub const APIKeyHeader = struct {
    name: []const u8,
    auto_error: bool = true,

    pub fn init(name: []const u8) APIKeyHeader {
        return .{ .name = name };
    }

    pub fn extract(self: APIKeyHeader, req: *const request.Request) ?[]const u8 {
        return req.header(self.name);
    }
};

pub const APIKeyQuery = struct {
    name: []const u8,
    auto_error: bool = true,

    pub fn init(name: []const u8) APIKeyQuery {
        return .{ .name = name };
    }

    pub fn extract(self: APIKeyQuery, req: *const request.Request) ?[]const u8 {
        return req.queryParam(self.name);
    }
};

pub const APIKeyCookie = struct {
    name: []const u8,
    auto_error: bool = true,

    pub fn init(name: []const u8) APIKeyCookie {
        return .{ .name = name };
    }

    pub fn extract(self: APIKeyCookie, req: *const request.Request) ?[]const u8 {
        return req.cookie(self.name);
    }
};

fn bearerToken(req: *const request.Request) ?[]const u8 {
    const authorization = req.header("authorization") orelse return null;
    const split = std.mem.indexOfScalar(u8, authorization, ' ') orelse return null;
    if (!std.ascii.eqlIgnoreCase(authorization[0..split], "bearer")) return null;
    return authorization[split + 1 ..];
}

pub fn unauthorized(detail: []const u8) HTTPException {
    return .{
        .status_code = status.HTTP_401_UNAUTHORIZED,
        .detail = detail,
        .headers = &.{.{ .name = "www-authenticate", .value = "Bearer" }},
    };
}
