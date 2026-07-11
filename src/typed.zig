const std = @import("std");
const dhi = @import("dhi");

const meta = @import("metadata.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const routing = @import("routing.zig");
const status = @import("status.zig");

pub const Empty = struct {};

pub const ParseError = error{
    MissingRequiredPathParam,
    MissingRequiredQueryParam,
    InvalidBool,
    UnsupportedParamType,
    ValidationFailed,
    OutOfMemory,
};

pub fn Context(comptime PathParams: type, comptime QueryParams: type) type {
    assertStruct(PathParams);
    assertStruct(QueryParams);

    return struct {
        raw: *request.Request,
        path: PathParams,
        query: QueryParams,
    };
}

pub fn ContextWithBody(comptime PathParams: type, comptime QueryParams: type, comptime BodyModel: type) type {
    assertStruct(PathParams);
    assertStruct(QueryParams);
    assertStruct(BodyModel);

    return struct {
        raw: *request.Request,
        path: PathParams,
        query: QueryParams,
        body: BodyModel,
    };
}

pub fn Handler(comptime PathParams: type, comptime QueryParams: type) type {
    return *const fn (Context(PathParams, QueryParams)) anyerror!response.Response;
}

pub fn HandlerWithBody(comptime PathParams: type, comptime QueryParams: type, comptime BodyModel: type) type {
    return *const fn (ContextWithBody(PathParams, QueryParams, BodyModel)) anyerror!response.Response;
}

pub fn adapt(
    comptime PathParams: type,
    comptime QueryParams: type,
    comptime handler: Handler(PathParams, QueryParams),
) routing.Handler {
    return struct {
        fn call(req: *request.Request) anyerror!response.Response {
            const path = parsePath(PathParams, req) catch |err| {
                return parseErrorResponse(req.allocator, err);
            };
            const query = parseQuery(QueryParams, req) catch |err| {
                return parseErrorResponse(req.allocator, err);
            };
            return handler(.{
                .raw = req,
                .path = path,
                .query = query,
            });
        }
    }.call;
}

pub fn adaptWithBody(
    comptime PathParams: type,
    comptime QueryParams: type,
    comptime BodyModel: type,
    comptime handler: HandlerWithBody(PathParams, QueryParams, BodyModel),
) routing.Handler {
    return struct {
        fn call(req: *request.Request) anyerror!response.Response {
            const path = parsePath(PathParams, req) catch |err| {
                return parseErrorResponse(req.allocator, err);
            };
            const query = parseQuery(QueryParams, req) catch |err| {
                return parseErrorResponse(req.allocator, err);
            };
            const body = parseBody(BodyModel, req) catch |err| {
                return parseErrorResponse(req.allocator, err);
            };
            return handler(.{
                .raw = req,
                .path = path,
                .query = query,
                .body = body,
            });
        }
    }.call;
}

pub fn get(
    api: anytype,
    comptime PathParams: type,
    comptime QueryParams: type,
    path: []const u8,
    comptime handler: Handler(PathParams, QueryParams),
    route_options: meta.RouteOptions,
) !void {
    const allocator = api.allocator;
    const generated = try allocParameters(allocator, PathParams, QueryParams);
    defer freeParameters(allocator, generated);

    var options = route_options;
    options.parameters = generated;
    try api.get(path, adapt(PathParams, QueryParams, handler), options);
}

pub fn postWithBody(
    api: anytype,
    comptime PathParams: type,
    comptime QueryParams: type,
    comptime BodyModel: type,
    path: []const u8,
    comptime handler: HandlerWithBody(PathParams, QueryParams, BodyModel),
    route_options: meta.RouteOptions,
) !void {
    const allocator = api.allocator;
    const generated = try allocParameters(allocator, PathParams, QueryParams);
    defer freeParameters(allocator, generated);

    var options = route_options;
    options.parameters = generated;
    try api.post(path, adaptWithBody(PathParams, QueryParams, BodyModel, handler), options);
}

pub fn parsePath(comptime T: type, req: *const request.Request) ParseError!T {
    assertStruct(T);
    const field_names = @typeInfo(T).@"struct".field_names;
    if (comptime field_names.len <= 1) return parseStruct(T, req, .path);
    return parsePathStruct(T, req);
}

pub fn parseQuery(comptime T: type, req: *const request.Request) ParseError!T {
    assertStruct(T);
    const field_names = @typeInfo(T).@"struct".field_names;
    if (comptime field_names.len <= 1) return parseStruct(T, req, .query);
    return parseQueryStruct(T, req);
}

pub fn parseBody(comptime T: type, req: *const request.Request) ParseError!T {
    assertStruct(T);

    // Most body models do not use DHI's naming-based validators. Use Zig's
    // direct typed JSON decoder for those models: it avoids constructing a
    // generic JSON value tree and an additional validation pass.
    if (comptime !needsDhiValidation(T)) {
        return std.json.parseFromSliceLeaky(T, req.allocator, req.body, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ValidationFailed,
        };
    }

    return dhi.parseAndValidate(T, req.body, req.allocator) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ValidationFailed,
    };
}

pub fn allocParameters(
    allocator: std.mem.Allocator,
    comptime PathParams: type,
    comptime QueryParams: type,
) ![]meta.Parameter {
    assertStruct(PathParams);
    assertStruct(QueryParams);

    const path_info = @typeInfo(PathParams).@"struct";
    const query_info = @typeInfo(QueryParams).@"struct";
    const total = path_info.field_names.len + query_info.field_names.len;

    const out = try allocator.alloc(meta.Parameter, total);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer freeParameters(allocator, out[0..initialized]);

    inline for (path_info.field_names, path_info.field_types, path_info.field_attrs) |name, field_type, attrs| {
        out[initialized] = try makeParameter(allocator, name, field_type, attrs, .path);
        initialized += 1;
    }
    inline for (query_info.field_names, query_info.field_types, query_info.field_attrs) |name, field_type, attrs| {
        out[initialized] = try makeParameter(allocator, name, field_type, attrs, .query);
        initialized += 1;
    }

    return out;
}

pub fn freeParameters(allocator: std.mem.Allocator, params: []meta.Parameter) void {
    for (params) |param| {
        allocator.free(param.name);
    }
    allocator.free(params);
}

fn parseStruct(comptime T: type, req: *const request.Request, comptime location: meta.Location) ParseError!T {
    assertStruct(T);
    var result: T = undefined;

    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, field_type, attrs| {
        switch (try parseField(field_type, req, name, location)) {
            .value => |value| @field(result, name) = value,
            .missing => {
                if (fieldDefault(field_type, attrs)) |default| {
                    @field(result, name) = default;
                } else if (comptime isOptional(field_type)) {
                    @field(result, name) = null;
                } else {
                    return missingRequiredError(location);
                }
            },
        }
    }

    if (comptime needsDhiValidation(T)) {
        try validateParsed(T, result, req.allocator);
    }
    return result;
}

fn parseQueryStruct(comptime T: type, req: *const request.Request) ParseError!T {
    assertStruct(T);

    const info = @typeInfo(T).@"struct";
    if (comptime info.field_names.len == 0) return .{};

    var result: T = undefined;
    var seen: [info.field_names.len]bool = @splat(false);

    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, field_type, attrs, i| {
        if (fieldDefault(field_type, attrs)) |default| {
            @field(result, name) = default;
        } else if (comptime isOptional(field_type)) {
            @field(result, name) = null;
        } else {
            seen[i] = false;
        }
    }

    var pos: usize = 0;
    while (pos < req.query_string.len) {
        const pair_start = pos;
        const pair_end = std.mem.indexOfScalarPos(u8, req.query_string, pair_start, '&') orelse req.query_string.len;
        pos = if (pair_end < req.query_string.len) pair_end + 1 else req.query_string.len;

        const pair = req.query_string[pair_start..pair_end];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];

        var matched = false;
        inline for (info.field_names, info.field_types, 0..) |name, field_type, i| {
            if (!matched and !seen[i] and std.mem.eql(u8, key, name)) {
                @field(result, name) = try parseValue(field_type, value);
                seen[i] = true;
                matched = true;
            }
        }
    }

    inline for (info.field_types, info.field_attrs, 0..) |field_type, attrs, i| {
        if (!seen[i] and attrs.default_value_ptr == null and !isOptional(field_type)) {
            return error.MissingRequiredQueryParam;
        }
    }

    if (comptime needsDhiValidation(T)) {
        try validateParsed(T, result, req.allocator);
    }
    return result;
}

fn parsePathStruct(comptime T: type, req: *const request.Request) ParseError!T {
    assertStruct(T);

    const info = @typeInfo(T).@"struct";
    if (comptime info.field_names.len == 0) return .{};

    var result: T = undefined;
    var seen: [info.field_names.len]bool = @splat(false);

    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, field_type, attrs, i| {
        if (fieldDefault(field_type, attrs)) |default| {
            @field(result, name) = default;
        } else if (comptime isOptional(field_type)) {
            @field(result, name) = null;
        } else {
            seen[i] = false;
        }
    }

    const params = req.path_params orelse return error.MissingRequiredPathParam;
    for (params.entries()) |param| {
        var matched = false;
        inline for (info.field_names, info.field_types, 0..) |name, field_type, i| {
            if (!matched and !seen[i] and std.mem.eql(u8, param.key, name)) {
                @field(result, name) = try parsePathParamValue(field_type, param);
                seen[i] = true;
                matched = true;
            }
        }
    }

    inline for (info.field_types, info.field_attrs, 0..) |field_type, attrs, i| {
        if (!seen[i] and attrs.default_value_ptr == null and !isOptional(field_type)) {
            return error.MissingRequiredPathParam;
        }
    }

    if (comptime needsDhiValidation(T)) {
        try validateParsed(T, result, req.allocator);
    }
    return result;
}

fn parsePathParamValue(comptime T: type, param: @import("turboapi-core").RouteParam) ParseError!T {
    if (comptime valueKind(T) == .int) {
        if (!param.has_int_value) return error.UnsupportedParamType;
        return std.math.cast(T, param.int_value) orelse error.UnsupportedParamType;
    }
    return parseValue(T, param.value);
}

fn validateParsed(comptime T: type, value: T, allocator: std.mem.Allocator) ParseError!void {
    var errors = dhi.ValidationErrors.init(allocator);
    defer errors.deinit();

    dhi.validateStruct(T, value, &errors) catch return error.OutOfMemory;
    if (errors.hasErrors()) return error.ValidationFailed;
}

fn parseErrorResponse(allocator: std.mem.Allocator, err: anyerror) !response.Response {
    return response.jsonError(
        allocator,
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        @errorName(err),
        &.{},
    );
}

fn ParsedField(comptime T: type) type {
    return union(enum) {
        missing,
        value: T,
    };
}

fn parseField(
    comptime T: type,
    req: *const request.Request,
    comptime name: []const u8,
    comptime location: meta.Location,
) ParseError!ParsedField(T) {
    switch (location) {
        .path => {
            if (comptime valueKind(T) == .int) {
                return parsePathIntField(T, req, name);
            }
            const raw = req.pathParam(name) orelse return .missing;
            return .{ .value = try parseValue(T, raw) };
        },
        .query => {
            const raw = req.queryParam(name) orelse return .missing;
            return .{ .value = try parseValue(T, raw) };
        },
        else => unreachable,
    }
}

fn parsePathIntField(comptime T: type, req: *const request.Request, comptime name: []const u8) ParseError!ParsedField(T) {
    const params = req.path_params orelse return .missing;
    for (params.entries()) |param| {
        if (std.mem.eql(u8, param.key, name)) {
            if (!param.has_int_value) return error.UnsupportedParamType;
            const value = std.math.cast(T, param.int_value) orelse return error.UnsupportedParamType;
            return .{ .value = value };
        }
    }
    return .missing;
}

fn missingRequiredError(comptime location: meta.Location) ParseError {
    return switch (location) {
        .path => error.MissingRequiredPathParam,
        .query => error.MissingRequiredQueryParam,
        else => unreachable,
    };
}

const ValueKind = enum {
    bool,
    int,
    float,
    optional,
    string_slice,
    unsupported,
};

fn valueKind(comptime T: type) ValueKind {
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int => .int,
        .float => .float,
        .optional => .optional,
        .pointer => |info| if (info.size == .slice and info.child == u8) .string_slice else .unsupported,
        else => .unsupported,
    };
}

fn optionalChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => @compileError("expected optional type"),
    };
}

fn parseValue(comptime T: type, raw: []const u8) ParseError!T {
    return switch (comptime valueKind(T)) {
        .bool => parseBool(raw),
        .int => std.fmt.parseInt(T, raw, 10) catch error.UnsupportedParamType,
        .float => std.fmt.parseFloat(T, raw) catch error.UnsupportedParamType,
        .optional => if (raw.len == 0) null else try parseValue(optionalChild(T), raw),
        .string_slice => raw,
        .unsupported => error.UnsupportedParamType,
    };
}

fn parseBool(raw: []const u8) ParseError!bool {
    switch (raw.len) {
        1 => switch (raw[0]) {
            '1' => return true,
            '0' => return false,
            else => {},
        },
        2 => {
            if (std.ascii.eqlIgnoreCase(raw, "on")) return true;
            if (std.ascii.eqlIgnoreCase(raw, "no")) return false;
        },
        3 => {
            if (std.ascii.eqlIgnoreCase(raw, "yes")) return true;
            if (std.ascii.eqlIgnoreCase(raw, "off")) return false;
        },
        4 => if (std.ascii.eqlIgnoreCase(raw, "true")) return true,
        5 => if (std.ascii.eqlIgnoreCase(raw, "false")) return false,
        else => {},
    }
    return error.InvalidBool;
}

fn fieldDefault(comptime T: type, attrs: std.builtin.Type.Struct.FieldAttributes) ?T {
    const ptr = attrs.default_value_ptr orelse return null;
    const value_ptr: *const T = @ptrCast(@alignCast(ptr));
    return value_ptr.*;
}

fn makeParameter(
    allocator: std.mem.Allocator,
    name: []const u8,
    comptime field_type: type,
    attrs: std.builtin.Type.Struct.FieldAttributes,
    comptime location: meta.Location,
) !meta.Parameter {
    return .{
        .name = try allocator.dupe(u8, name),
        .location = location,
        .schema_type = schemaType(field_type),
        .required = location == .path or (attrs.default_value_ptr == null and !isOptional(field_type)),
    };
}

fn schemaType(comptime T: type) meta.SchemaType {
    return switch (comptime valueKind(T)) {
        .bool => .boolean,
        .int => .integer,
        .float => .number,
        .optional => schemaType(optionalChild(T)),
        .string_slice => .string,
        .unsupported => .any,
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn needsDhiValidation(comptime T: type) bool {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (std.mem.endsWith(u8, name, "_ne")) return true;
        if (std.mem.eql(u8, name, "email") or std.mem.endsWith(u8, name, "_email")) return true;
    }
    return false;
}

fn assertStruct(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError("typed path/query parameter declarations must be structs, got " ++ @typeName(T));
    }
}

test "typed bool parser accepts supported forms" {
    const cases = [_]struct {
        raw: []const u8,
        value: bool,
    }{
        .{ .raw = "true", .value = true },
        .{ .raw = "TRUE", .value = true },
        .{ .raw = "1", .value = true },
        .{ .raw = "on", .value = true },
        .{ .raw = "YES", .value = true },
        .{ .raw = "false", .value = false },
        .{ .raw = "FALSE", .value = false },
        .{ .raw = "0", .value = false },
        .{ .raw = "off", .value = false },
        .{ .raw = "NO", .value = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.value, try parseValue(bool, case.raw));
    }
    try std.testing.expectError(error.InvalidBool, parseValue(bool, "truthy"));
}

test "typed path integer parser uses route param cache" {
    const core = @import("turboapi-core");

    var req = request.Request.init(std.testing.allocator, "GET", "/items/42", &.{}, "");
    var params = core.RouteParams{};
    params.put("id", "42");
    req.setPathParams(&params);

    const PathParams = struct {
        id: i8,
    };

    const parsed = try parsePath(PathParams, &req);
    try std.testing.expectEqual(@as(i8, 42), parsed.id);
}

test "typed path parser scans route params once for multiple fields" {
    const core = @import("turboapi-core");

    var req = request.Request.init(std.testing.allocator, "GET", "/orgs/7/users/42", &.{}, "");
    var params = core.RouteParams{};
    params.put("org_id", "7");
    params.put("user_id", "42");
    params.put("slug", "rach");
    req.setPathParams(&params);

    const PathParams = struct {
        org_id: u8,
        user_id: i16,
        slug: []const u8,
    };

    const parsed = try parsePath(PathParams, &req);
    try std.testing.expectEqual(@as(u8, 7), parsed.org_id);
    try std.testing.expectEqual(@as(i16, 42), parsed.user_id);
    try std.testing.expectEqualStrings("rach", parsed.slug);
}

test "typed query parser uses first value and defaults" {
    var req = request.Request.init(std.testing.allocator, "GET", "/items?verbose=true&limit=10&verbose=false", &.{}, "");

    const QueryParams = struct {
        verbose: bool = false,
        limit: u8,
        cursor: ?[]const u8 = null,
    };

    const parsed = try parseQuery(QueryParams, &req);
    try std.testing.expect(parsed.verbose);
    try std.testing.expectEqual(@as(u8, 10), parsed.limit);
    try std.testing.expect(parsed.cursor == null);
}
