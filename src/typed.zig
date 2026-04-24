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
    return parseStruct(T, req, .path);
}

pub fn parseQuery(comptime T: type, req: *const request.Request) ParseError!T {
    return parseStruct(T, req, .query);
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
        const raw = switch (location) {
            .path => req.pathParam(field.name),
            .query => req.queryParam(field.name),
            else => unreachable,
        };

        if (raw) |value| {
            @field(result, field.name) = try parseFieldValue(field.type, req, field.name, value, location);
        } else if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
        } else if (comptime isOptional(field.type)) {
            @field(result, field.name) = null;
        } else {
            return switch (location) {
                .path => error.MissingRequiredPathParam,
                .query => error.MissingRequiredQueryParam,
                else => unreachable,
            };
        }
    }

    try validateParsed(T, result, req.allocator);
    return result;
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

fn parseFieldValue(
    comptime T: type,
    req: *const request.Request,
    comptime name: []const u8,
    raw: []const u8,
    comptime location: meta.Location,
) ParseError!T {
    if (location == .path and @typeInfo(T) == .int) {
        const value = req.pathInt(name) orelse return error.UnsupportedParamType;
        return std.math.cast(T, value) orelse error.UnsupportedParamType;
    }
    return parseValue(T, raw);
}

fn parseValue(comptime T: type, raw: []const u8) ParseError!T {
    return switch (@typeInfo(T)) {
        .bool => parseBool(raw),
        .int => std.fmt.parseInt(T, raw, 10) catch error.UnsupportedParamType,
        .float => std.fmt.parseFloat(T, raw) catch error.UnsupportedParamType,
        .optional => |info| if (raw.len == 0) null else try parseValue(info.child, raw),
        .pointer => |info| blk: {
            if (info.size == .slice and info.child == u8) break :blk raw;
            return error.UnsupportedParamType;
        },
        else => error.UnsupportedParamType,
    };
}

fn parseBool(raw: []const u8) ParseError!bool {
    if (std.ascii.eqlIgnoreCase(raw, "true") or
        std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "on") or
        std.ascii.eqlIgnoreCase(raw, "yes"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(raw, "false") or
        std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "off") or
        std.ascii.eqlIgnoreCase(raw, "no"))
    {
        return false;
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
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int => .integer,
        .float => .number,
        .optional => |info| schemaType(info.child),
        .pointer => |info| if (info.size == .slice and info.child == u8) .string else .any,
        else => .any,
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn assertStruct(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError("typed path/query parameter declarations must be structs, got " ++ @typeName(T));
    }
}
