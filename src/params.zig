const meta = @import("metadata.zig");

pub const Location = meta.Location;
pub const SchemaType = meta.SchemaType;
pub const Parameter = meta.Parameter;
pub const ParameterOptions = meta.ParameterOptions;

fn makeParameter(
    name: []const u8,
    location: Location,
    schema_type: SchemaType,
    options: ParameterOptions,
) Parameter {
    return .{
        .name = name,
        .location = location,
        .schema_type = schema_type,
        .required = options.required,
        .default = options.default,
        .alias = options.alias,
        .title = options.title,
        .description = options.description,
        .min_length = options.min_length,
        .max_length = options.max_length,
        .gt = options.gt,
        .ge = options.ge,
        .lt = options.lt,
        .le = options.le,
    };
}

pub fn Path(name: []const u8, schema_type: SchemaType, options: ParameterOptions) Parameter {
    var opts = options;
    opts.required = true;
    return makeParameter(name, .path, schema_type, opts);
}

pub fn Query(name: []const u8, schema_type: SchemaType, options: ParameterOptions) Parameter {
    return makeParameter(name, .query, schema_type, options);
}

pub fn Header(name: []const u8, schema_type: SchemaType, options: ParameterOptions) Parameter {
    return makeParameter(name, .header, schema_type, options);
}

pub fn Cookie(name: []const u8, schema_type: SchemaType, options: ParameterOptions) Parameter {
    return makeParameter(name, .cookie, schema_type, options);
}

pub fn Body(name: []const u8, schema_type: SchemaType, options: ParameterOptions) Parameter {
    return makeParameter(name, .body, schema_type, options);
}

pub fn Form(name: []const u8, schema_type: SchemaType, options: ParameterOptions) Parameter {
    return makeParameter(name, .form, schema_type, options);
}

pub fn File(name: []const u8, options: ParameterOptions) Parameter {
    return makeParameter(name, .file, .binary, options);
}
