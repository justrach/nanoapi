pub const Location = enum {
    path,
    query,
    header,
    cookie,
    body,
    form,
    file,
};

pub const SchemaType = enum {
    string,
    integer,
    number,
    boolean,
    object,
    array,
    binary,
    any,
};

pub const ParameterOptions = struct {
    required: bool = true,
    default: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    gt: ?f64 = null,
    ge: ?f64 = null,
    lt: ?f64 = null,
    le: ?f64 = null,
};

pub const Parameter = struct {
    name: []const u8,
    location: Location,
    schema_type: SchemaType = .string,
    required: bool = true,
    default: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    gt: ?f64 = null,
    ge: ?f64 = null,
    lt: ?f64 = null,
    le: ?f64 = null,
};

pub const RouteOptions = struct {
    name: ?[]const u8 = null,
    response_model: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    parameters: []const Parameter = &.{},
    status_code: u16 = 200,
};
