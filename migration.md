# Zig 0.17 Migration

NanoAPI now targets the Zig 0.17 development toolchain.

## Toolchain

The repository uses Zig 0.17-dev through `zigup` and CI tracks the Zig
development compiler (`master`). Check the active compiler with:

```bash
zig version
```

The package minimum is declared in `build.zig.zon` as `0.17.0-dev`.

## Reflection API changes

Zig 0.17 replaced the old `std.builtin.Type.StructField` reflection shape:

```zig
@typeInfo(T).@"struct".fields
field.name
field.type
field.defaultValue()
```

with parallel reflection arrays:

```zig
const info = @typeInfo(T).@"struct";
info.field_names
info.field_types
info.field_attrs
```

Defaults are read from `field_attrs[i].default_value_ptr` and cast to the
corresponding field type. NanoAPI's typed path, query, schema, and validation
code has been migrated to this representation.

## Dependency compatibility

The currently pinned upstream revisions of `dhi` and `turboapi-core` still
contained pre-0.17 reflection and array-repetition syntax. Zig 0.17-compatible
snapshots are temporarily vendored under:

- `vendor/dhi`
- `vendor/turboapi-core`

They retain their upstream licenses and public APIs. Upstream migration issues
were opened so these snapshots can be removed once compatible upstream commits
are released:

- dhi: https://github.com/justrach/dhi/issues/69
- turboapi-core: https://github.com/justrach/turboapi-core/issues/3
- NanoAPI tracking issue: https://github.com/justrach/nanoapi/issues/23

The desired long-term follow-up is to replace the path dependencies in
`build.zig.zon` with released upstream revisions.

## Performance changes

Typed body parsing now has a fast path for models that do not use DHI's
naming-based validators. It uses Zig's direct typed JSON decoder instead of
building a generic JSON value tree and running a second validation pass.
Models that require DHI validation continue to use DHI.

Benchmark options are exposed through the Zig 0.17 build API:

```bash
zig build -Doptimize=ReleaseFast bench \
  -Dbench-iterations=1000000 \
  -Dbench-warmup=100000 \
  -Dbench-repeat=5 \
  -Dbench-json=true
```

The migration comparison harness is:

```bash
./scripts/bench-zig-compare.sh
```

It compares the pre-migration `HEAD` baseline under Zig 0.16 with the current
working tree under Zig 0.17. Since the current tree also includes dependency
and reflection migrations, it is a migration A/B comparison rather than a
compiler-only benchmark.

## Verification

Run the standard checks with:

```bash
zig fmt --check build.zig src bench vendor
zig build
zig build test
```
