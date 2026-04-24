const std = @import("std");

const meta = @import("metadata.zig");
const routing = @import("routing.zig");

pub fn generate(
    allocator: std.mem.Allocator,
    title: []const u8,
    version: []const u8,
    description: []const u8,
    routes: []const routing.RouteDefinition,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":");
    try appendJsonString(&out, allocator, title);
    try out.appendSlice(allocator, ",\"version\":");
    try appendJsonString(&out, allocator, version);
    try out.appendSlice(allocator, ",\"description\":");
    try appendJsonString(&out, allocator, description);
    try out.appendSlice(allocator, "},\"paths\":{");

    var first_path = true;
    for (routes, 0..) |route_def, i| {
        if (pathSeen(routes, i, route_def.path)) continue;
        if (!first_path) try out.append(allocator, ',');
        first_path = false;

        try appendJsonString(&out, allocator, route_def.path);
        try out.appendSlice(allocator, ":{");

        var first_method = true;
        for (routes) |candidate| {
            if (!std.mem.eql(u8, candidate.path, route_def.path)) continue;
            if (!first_method) try out.append(allocator, ',');
            first_method = false;

            try out.append(allocator, '"');
            try appendLower(&out, allocator, candidate.method);
            try out.appendSlice(allocator, "\":");
            try appendOperation(&out, allocator, candidate);
        }

        try out.append(allocator, '}');
    }

    try out.appendSlice(allocator, "},\"components\":{\"schemas\":{}}}");
    return out.toOwnedSlice(allocator);
}

fn appendOperation(out: *std.ArrayList(u8), allocator: std.mem.Allocator, route_def: routing.RouteDefinition) !void {
    try out.appendSlice(allocator, "{\"summary\":");
    try appendJsonString(out, allocator, route_def.options.summary orelse route_def.options.name orelse route_def.path);
    try out.appendSlice(allocator, ",\"operationId\":");
    try appendJsonString(out, allocator, route_def.options.name orelse route_def.key);

    if (route_def.options.description) |description| {
        try out.appendSlice(allocator, ",\"description\":");
        try appendJsonString(out, allocator, description);
    }

    if (route_def.options.tags.len > 0) {
        try out.appendSlice(allocator, ",\"tags\":[");
        for (route_def.options.tags, 0..) |tag, i| {
            if (i > 0) try out.append(allocator, ',');
            try appendJsonString(out, allocator, tag);
        }
        try out.append(allocator, ']');
    }

    try appendParameters(out, allocator, route_def.options.parameters);
    try appendRequestBody(out, allocator, route_def.options.parameters);

    try out.appendSlice(allocator, ",\"responses\":{");
    try out.print(allocator, "\"{d}\":{{\"description\":\"Successful Response\",\"content\":{{\"application/json\":{{\"schema\":{{}}}}}}}}", .{route_def.options.status_code});
    try out.appendSlice(allocator, ",\"422\":{\"description\":\"Validation Error\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\"}}}}");
    try out.appendSlice(allocator, "}}");
}

fn appendParameters(out: *std.ArrayList(u8), allocator: std.mem.Allocator, params: []const meta.Parameter) !void {
    var first = true;
    for (params) |param| {
        if (isBodyParam(param.location)) continue;
        if (first) {
            try out.appendSlice(allocator, ",\"parameters\":[");
            first = false;
        } else {
            try out.append(allocator, ',');
        }

        try out.appendSlice(allocator, "{\"name\":");
        try appendJsonString(out, allocator, param.alias orelse param.name);
        try out.appendSlice(allocator, ",\"in\":");
        try appendJsonString(out, allocator, locationName(param.location));
        try out.appendSlice(allocator, ",\"required\":");
        try out.appendSlice(allocator, if (param.location == .path or param.required) "true" else "false");
        try out.appendSlice(allocator, ",\"schema\":");
        try appendSchema(out, allocator, param);
        if (param.description) |description| {
            try out.appendSlice(allocator, ",\"description\":");
            try appendJsonString(out, allocator, description);
        }
        try out.append(allocator, '}');
    }
    if (!first) try out.append(allocator, ']');
}

fn appendRequestBody(out: *std.ArrayList(u8), allocator: std.mem.Allocator, params: []const meta.Parameter) !void {
    var has_body = false;
    var multipart = false;
    for (params) |param| {
        if (isBodyParam(param.location)) {
            has_body = true;
            if (param.location == .form or param.location == .file) multipart = true;
        }
    }
    if (!has_body) return;

    try out.appendSlice(allocator, ",\"requestBody\":{\"required\":true,\"content\":{");
    try appendJsonString(out, allocator, if (multipart) "multipart/form-data" else "application/json");
    try out.appendSlice(allocator, ":{\"schema\":{\"type\":\"object\",\"properties\":{");

    var first = true;
    for (params) |param| {
        if (!isBodyParam(param.location)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendJsonString(out, allocator, param.alias orelse param.name);
        try out.append(allocator, ':');
        try appendSchema(out, allocator, param);
    }

    try out.appendSlice(allocator, "}}}}}");
}

fn appendSchema(out: *std.ArrayList(u8), allocator: std.mem.Allocator, param: meta.Parameter) !void {
    try out.appendSlice(allocator, "{\"type\":");
    try appendJsonString(out, allocator, schemaTypeName(param.schema_type));
    if (param.schema_type == .binary) {
        try out.appendSlice(allocator, ",\"format\":\"binary\"");
    }
    if (param.default) |default| {
        try out.appendSlice(allocator, ",\"default\":");
        try appendJsonString(out, allocator, default);
    }
    if (param.title) |title| {
        try out.appendSlice(allocator, ",\"title\":");
        try appendJsonString(out, allocator, title);
    }
    if (param.min_length) |value| try out.print(allocator, ",\"minLength\":{d}", .{value});
    if (param.max_length) |value| try out.print(allocator, ",\"maxLength\":{d}", .{value});
    if (param.gt) |value| try out.print(allocator, ",\"exclusiveMinimum\":{d}", .{value});
    if (param.ge) |value| try out.print(allocator, ",\"minimum\":{d}", .{value});
    if (param.lt) |value| try out.print(allocator, ",\"exclusiveMaximum\":{d}", .{value});
    if (param.le) |value| try out.print(allocator, ",\"maximum\":{d}", .{value});
    try out.append(allocator, '}');
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

fn appendLower(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |ch| try out.append(allocator, std.ascii.toLower(ch));
}

fn pathSeen(routes: []const routing.RouteDefinition, index: usize, path: []const u8) bool {
    for (routes[0..index]) |route_def| {
        if (std.mem.eql(u8, route_def.path, path)) return true;
    }
    return false;
}

fn isBodyParam(location: meta.Location) bool {
    return location == .body or location == .form or location == .file;
}

fn locationName(location: meta.Location) []const u8 {
    return switch (location) {
        .path => "path",
        .query => "query",
        .header => "header",
        .cookie => "cookie",
        .body, .form, .file => "body",
    };
}

fn schemaTypeName(schema_type: meta.SchemaType) []const u8 {
    return switch (schema_type) {
        .string => "string",
        .integer => "integer",
        .number => "number",
        .boolean => "boolean",
        .object => "object",
        .array => "array",
        .binary => "string",
        .any => "object",
    };
}
