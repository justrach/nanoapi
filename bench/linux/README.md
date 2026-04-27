# Linux io_uring benchmark suite

End-to-end reproducer for the Linux io_uring runtime numbers shown in the
top-level `Performance` section. The suite cross-compiles
`bench/http_server.zig` for `aarch64-linux-musl`, packages it with
`wrk 4.2.0` into an Alpine image, and runs the wrk suite from inside the
same OCI container against `127.0.0.1` so the wire is in-VM kernel loopback
(no virtio-net, no host bridge).

Tested with [Apple `container`](https://github.com/apple/container) 0.11
on macOS 26.4 (kernel 6.18.5 inside the VM). Should also work with `docker`
or `podman` — set `RUNTIME=docker` and pick the right `TARGET`.

## Running

```sh
# from the repo root
./bench/linux/run.sh
```

Tunables (env vars):

| var        | default               | meaning                                |
|------------|-----------------------|----------------------------------------|
| `RUNTIME`  | `container`           | OCI CLI to invoke (also `docker`)      |
| `TARGET`   | `aarch64-linux-musl`  | Zig cross-compile target               |
| `IMAGE`    | `nano-bench:latest`   | image tag                              |
| `NAME`     | `nano-bench`          | container name                         |
| `CPUS`     | `8`                   | vCPU allocation                        |
| `MEM`      | `4096M`               | memory allocation                      |
| `WORKERS`  | `4`                   | nanoapi worker count                   |
| `DURATION` | `15s`                 | wrk `-d` duration                      |

## Layout

```
bench/linux/
├── Containerfile        nanoapi server image (alpine + wrk + binary)
├── run.sh               build → run → bench → tear down
├── pipeline.lua         16-request pipelined wrk script
├── post-users.lua       POST body matching bench/http_server.zig BodyModel
├── auth-headers.lua     Authorization + Cookie session= for /auth
└── comparison/
    ├── fiber/           Go Fiber 2.52 server + Containerfile
    └── actix/           actix-web 4.9 server + Containerfile
```

## Comparing against Fiber / actix-web

```sh
container build -t fiber-bench -f bench/linux/comparison/fiber/Containerfile bench/linux/comparison/fiber
container run -d --name fb --rm --cpus 8 -m 4096M \
  --mount type=bind,source=$PWD/bench/linux,target=/scripts,readonly fiber-bench
container exec fb wrk -t4 -c64 -d15s --latency -s /scripts/pipeline.lua http://127.0.0.1:8080/
container stop fb

container build -t actix-bench -f bench/linux/comparison/actix/Containerfile bench/linux/comparison/actix
container run -d --name ab --rm --cpus 8 -m 4096M \
  --mount type=bind,source=$PWD/bench/linux,target=/scripts,readonly actix-bench
container exec ab wrk -t4 -c64 -d15s --latency -s /scripts/pipeline.lua http://127.0.0.1:8080/
container stop ab
```

All three servers expose the same three routes (`GET /`, `POST /users`,
`GET /auth`) with matching JSON shapes, so the wrk lua scripts work
unchanged across them.

## Caveats

- Apple `container` runs each container in a lightweight VM; numbers will
  differ on bare metal. The point of the suite is *relative* comparison
  with everything sharing the same VM topology.
- `Prefork: true` for Fiber crashes under Apple container's rootfs (no
  re-exec of `/proc/self/exe`); the bench drops it and uses the default
  goroutine-per-connection model.
- actix-web `lto = "thin"`, not `"fat"`, to keep the build under five
  minutes. Fat-LTO would gain a few percent.
- `bench/http_server.zig`'s `parseRuntime` only knows `auto` /
  `event_loop` / `thread_per_connection`. `auto` is sufficient — on
  Linux it resolves to `io_uring` via `effectiveRuntime` in `src/server.zig`.
