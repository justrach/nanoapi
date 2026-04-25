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

pub fn Handler(comptime PathParams: type, comptime QueryParams: type) type {
    return *const fn (Context(PathParams, QueryParams)) anyerror!response.Response;
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

pub fn parsePath(comptime T: type, req: *const request.Request) ParseError!T {
    assertStruct(T);
    const fields = @typeInfo(T).@"struct".fields;
    if (comptime fields.len <= 1) return parseStruct(T, req, .path);
    return parsePathStruct(T, req);
}

pub fn parseQuery(comptime T: type, req: *const request.Request) ParseError!T {
    assertStruct(T);
    const fields = @typeInfo(T).@"struct".fields;
    if (comptime fields.len <= 1) return parseStruct(T, req, .query);
    return parseQueryStruct(T, req);
}

pub fn allocParameters(
    allocator: std.mem.Allocator,
    comptime PathParams: type,
    comptime QueryParams: type,
) ![]meta.Parameter {
    assertStruct(PathParams);
    assertStruct(QueryParams);

    const path_fields = @typeInfo(PathParams).@"struct".fields;
    const query_fields = @typeInfo(QueryParams).@"struct".fields;
    const total = path_fields.len + query_fields.len;

    const out = try allocator.alloc(meta.Parameter, total);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer freeParameters(allocator, out[0..initialized]);

    inline for (path_fields) |field| {
        out[initialized] = try makeParameter(allocator, field, .path);
        initialized += 1;
    }
    inline for (query_fields) |field| {
        out[initialized] = try makeParameter(allocator, field, .query);
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

    inline for (@typeInfo(T).@"struct".fields) |field| {
        switch (try parseField(field.type, req, field.name, location)) {
            .value => |value| @field(result, field.name) = value,
            .missing => {
                if (field.defaultValue()) |default| {
                    @field(result, field.name) = default;
                } else if (comptime isOptional(field.type)) {
                    @field(result, field.name) = null;
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

    const fields = @typeInfo(T).@"struct".fields;
    if (comptime fields.len == 0) return .{};

    var result: T = undefined;
    var seen = [_]bool{false} ** fields.len;

    inline for (fields, 0..) |field, i| {
        if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
        } else if (comptime isOptional(field.type)) {
            @field(result, field.name) = null;
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
        inline for (fields, 0..) |field, i| {
            if (!matched and !seen[i] and std.mem.eql(u8, key, field.name)) {
                @field(result, field.name) = try parseValue(field.type, value);
                seen[i] = true;
                matched = true;
            }
        }
    }

    inline for (fields, 0..) |field, i| {
        if (!seen[i] and field.default_value_ptr == null and !isOptional(field.type)) {
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

    const fields = @typeInfo(T).@"struct".fields;
    if (comptime fields.len == 0) return .{};

    var result: T = undefined;
    var seen = [_]bool{false} ** fields.len;

    inline for (fields, 0..) |field, i| {
        if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
        } else if (comptime isOptional(field.type)) {
            @field(result, field.name) = null;
        } else {
            seen[i] = false;
        }
    }

    const params = req.path_params orelse return error.MissingRequiredPathParam;
    for (params.entries()) |param| {
        var matched = false;
        inline for (fields, 0..) |field, i| {
            if (!matched and !seen[i] and std.mem.eql(u8, param.key, field.name)) {
                @field(result, field.name) = try parsePathParamValue(field.type, param);
                seen[i] = true;
                matched = true;
            }
        }
    }

    inline for (fields, 0..) |field, i| {
        if (!seen[i] and field.default_value_ptr == null and !isOptional(field.type)) {
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

fn makeParameter(
    allocator: std.mem.Allocator,
    comptime field: std.builtin.Type.StructField,
    comptime location: meta.Location,
) !meta.Parameter {
    return .{
        .name = try allocator.dupe(u8, field.name),
        .location = location,
        .schema_type = schemaType(field.type),
        .required = location == .path or (field.default_value_ptr == null and !isOptional(field.type)),
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
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.endsWith(u8, field.name, "_ne")) return true;
        if (std.mem.eql(u8, field.name, "email") or std.mem.endsWith(u8, field.name, "_email")) return true;
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
