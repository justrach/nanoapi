//! Linux io_uring runtime.
//!
//! This module mirrors the kqueue event-loop semantics in `server.zig` but uses
//! io_uring instead of synchronous recv/send. It reuses the same Connection
//! state (per-connection arena, batched write buffer, header cache) and the
//! same fast-JSON / static-dispatch shortcuts. Each connection has at most one
//! io_uring operation in flight at any time (alternating recv → send → recv …),
//! which keeps lifecycle management straightforward: the CQE handler always
//! finds the connection with no pending op and is free to either submit the
//! next op or `linux.close` the fd and destroy the connection inline.
//!
//! Non-fast-path responses (file, stream, custom headers, HEAD requests) are
//! flushed via a synchronous `send(2)` before submitting the next recv. They
//! still work correctly; they just don't benefit from io_uring batching.
//!
//! Compiles on every target (so `zig build` doesn't need conditional includes),
//! but `run` returns `error.IoUringNotSupported` when invoked on non-Linux.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const posix = std.posix;

const app_mod = @import("app.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const routing = @import("routing.zig");
const server_mod = @import("server.zig");
const status = @import("status.zig");

const Allocator = std.mem.Allocator;
const Server = server_mod.Server;

pub const Available = builtin.os.tag == .linux;

/// `user_data == 0` is reserved for the multishot accept on the listen socket.
const ACCEPT_TAG: u64 = 0;

/// Tag bits packed into the low bit of a Connection pointer (8-byte aligned).
const Op = enum(u1) { recv = 0, send = 1 };
const TAG_MASK: u64 = 0b1;
const PTR_MASK: u64 = ~TAG_MASK;

inline fn encodeUserData(conn: *IoConn, op: Op) u64 {
    return @intFromPtr(conn) | @as(u64, @intFromEnum(op));
}

inline fn decodeConn(user_data: u64) *IoConn {
    return @ptrFromInt(user_data & PTR_MASK);
}

inline fn decodeOp(user_data: u64) Op {
    return @enumFromInt(@as(u1, @intCast(user_data & TAG_MASK)));
}

/// Per-connection state. Mirrors `server.Connection` but is io_uring-owned —
/// allocations live in `server.allocator` and the Connection is destroyed as
/// soon as we decide to close (we never hold pending ops past that point).
const IoConn = struct {
    server: *Server,
    fd: linux.fd_t,
    arena: std.heap.ArenaAllocator,
    headers: []request.HeaderPair,
    input_buf: []u8,
    input_head: usize = 0,
    input_len: usize = 0,
    write_buf: []u8,
    write_len: usize = 0,
    write_sent: usize = 0,
    /// When true, close the fd as soon as the current send drains.
    close_after_send: bool = false,

    fn create(server: *Server, fd: linux.fd_t) !*IoConn {
        const conn = try server.allocator.create(IoConn);
        errdefer server.allocator.destroy(conn);

        const input_buf = try server.allocator.alloc(u8, server.options.read_buffer_size);
        errdefer server.allocator.free(input_buf);

        const write_buf = try server.allocator.alloc(u8, server.options.write_buffer_size);
        errdefer server.allocator.free(write_buf);

        const headers = try server.allocator.alloc(request.HeaderPair, server.options.max_headers);
        errdefer server.allocator.free(headers);

        conn.* = .{
            .server = server,
            .fd = fd,
            .arena = std.heap.ArenaAllocator.init(server.allocator),
            .headers = headers,
            .input_buf = input_buf,
            .write_buf = write_buf,
        };
        return conn;
    }

    fn deinit(self: *IoConn) void {
        self.arena.deinit();
        _ = linux.close(self.fd);
        self.server.allocator.free(self.input_buf);
        self.server.allocator.free(self.write_buf);
        self.server.allocator.free(self.headers);
        self.server.allocator.destroy(self);
    }

    fn inputBytes(self: *const IoConn) []const u8 {
        return self.input_buf[self.input_head .. self.input_head + self.input_len];
    }

    fn inputCapacity(self: *const IoConn) usize {
        return self.input_buf.len - self.input_head;
    }

    /// Reclaim head space for the next recv if needed.
    fn compactInput(self: *IoConn) void {
        if (self.input_head + self.input_len < self.input_buf.len) return;
        if (self.input_head == 0) return;
        if (self.input_len > 0) {
            std.mem.copyForwards(
                u8,
                self.input_buf[0..self.input_len],
                self.input_buf[self.input_head .. self.input_head + self.input_len],
            );
        }
        self.input_head = 0;
    }

    fn consume(self: *IoConn, amount: usize) void {
        if (amount >= self.input_len) {
            self.input_head = 0;
            self.input_len = 0;
            return;
        }
        self.input_head += amount;
        self.input_len -= amount;
    }

    /// Per-connection write buffer view that's currently pending send.
    fn pendingWrite(self: *const IoConn) []const u8 {
        return self.write_buf[self.write_sent..self.write_len];
    }

    fn writeRoom(self: *const IoConn) usize {
        return self.write_buf.len - self.write_len;
    }

    fn appendStaticBytes(self: *IoConn, bytes: []const u8) bool {
        if (bytes.len > self.writeRoom()) return false;
        @memcpy(self.write_buf[self.write_len..][0..bytes.len], bytes);
        self.write_len += bytes.len;
        return true;
    }

    fn appendFastJsonBytes(self: *IoConn, body: []const u8) bool {
        const prefix = "HTTP/1.1 200 OK\r\nContent-Length: ";
        const middle = "\r\nContent-Type: application/json\r\n\r\n";
        const max_record_len = prefix.len + 20 + middle.len + body.len;
        if (max_record_len > self.writeRoom()) return false;

        var len = self.write_len;
        @memcpy(self.write_buf[len..][0..prefix.len], prefix);
        len += prefix.len;
        len += server_mod.appendDecimal(self.write_buf[len..], body.len);
        @memcpy(self.write_buf[len..][0..middle.len], middle);
        len += middle.len;
        @memcpy(self.write_buf[len..][0..body.len], body);
        len += body.len;
        self.write_len = len;
        return true;
    }
};

/// Run the io_uring loop for a single worker. `listen_fd` must already be in
/// listen state. The caller is responsible for spawning multiple workers if
/// desired; this function never returns under normal operation.
pub fn run(server: *Server, listen_fd: linux.fd_t) !void {
    if (comptime !Available) return error.IoUringNotSupported;

    var ring = try linux.IoUring.init(server.options.io_uring_entries, 0);
    defer ring.deinit();

    // Issue a multishot accept that lives for the whole loop. The kernel will
    // post a fresh CQE for every incoming connection without us re-submitting.
    _ = ring.accept_multishot(ACCEPT_TAG, listen_fd, null, null, 0) catch |err| {
        // accept_multishot needs Linux 5.19+. On older kernels fall back to
        // re-submitting plain accept after each CQE.
        if (err == error.SubmissionQueueFull) return err;
        return runWithSingleshotAccept(server, listen_fd, &ring);
    };

    var cqes: [256]linux.io_uring_cqe = undefined;
    while (true) {
        _ = try ring.submit_and_wait(1);
        const n = try ring.copy_cqes(&cqes, 0);
        for (cqes[0..n]) |cqe| {
            handleCqe(server, &ring, listen_fd, cqe, true) catch continue;
        }
    }
}

fn runWithSingleshotAccept(server: *Server, listen_fd: linux.fd_t, ring: *linux.IoUring) !void {
    _ = try ring.accept(ACCEPT_TAG, listen_fd, null, null, 0);
    var cqes: [256]linux.io_uring_cqe = undefined;
    while (true) {
        _ = try ring.submit_and_wait(1);
        const n = try ring.copy_cqes(&cqes, 0);
        for (cqes[0..n]) |cqe| {
            handleCqe(server, ring, listen_fd, cqe, false) catch continue;
        }
    }
}

fn handleCqe(
    server: *Server,
    ring: *linux.IoUring,
    listen_fd: linux.fd_t,
    cqe: linux.io_uring_cqe,
    multishot_accept: bool,
) !void {
    if (cqe.user_data == ACCEPT_TAG) {
        // Re-arm singleshot accept up front so we don't drop incoming
        // connections while we're processing this one.
        if (!multishot_accept) {
            _ = ring.accept(ACCEPT_TAG, listen_fd, null, null, 0) catch {};
        }
        if (cqe.res < 0) return; // accept failed; multishot will keep going
        const fd: linux.fd_t = @intCast(cqe.res);
        configureAcceptedSocket(fd);
        const conn = IoConn.create(server, fd) catch {
            _ = linux.close(fd);
            return;
        };
        try submitRecv(ring, conn);
        return;
    }

    const conn = decodeConn(cqe.user_data);
    switch (decodeOp(cqe.user_data)) {
        .recv => try onRecv(ring, conn, cqe.res),
        .send => try onSend(ring, conn, cqe.res),
    }
}

fn submitRecv(ring: *linux.IoUring, conn: *IoConn) !void {
    conn.compactInput();
    const tail = conn.input_head + conn.input_len;
    const slice = conn.input_buf[tail..];
    if (slice.len == 0) {
        // Buffer full and nothing to compact — protocol error from the client.
        conn.deinit();
        return;
    }
    _ = ring.recv(encodeUserData(conn, .recv), conn.fd, .{ .buffer = slice }, 0) catch {
        conn.deinit();
        return;
    };
}

fn submitSend(ring: *linux.IoUring, conn: *IoConn) !void {
    const slice = conn.pendingWrite();
    if (slice.len == 0) {
        if (conn.close_after_send) {
            conn.deinit();
            return;
        }
        return submitRecv(ring, conn);
    }
    _ = ring.send(encodeUserData(conn, .send), conn.fd, slice, 0) catch {
        conn.deinit();
        return;
    };
}

fn onRecv(ring: *linux.IoUring, conn: *IoConn, res: i32) !void {
    if (res <= 0) {
        // res == 0 → orderly shutdown. res < 0 → error (already negated errno).
        conn.deinit();
        return;
    }
    conn.input_len += @intCast(res);

    const action = processRequests(conn);
    switch (action) {
        .need_more_data => return submitRecv(ring, conn),
        .send_then_close => {
            conn.close_after_send = true;
            return submitSend(ring, conn);
        },
        .send_then_recv => return submitSend(ring, conn),
        .close => {
            conn.deinit();
            return;
        },
    }
}

fn onSend(ring: *linux.IoUring, conn: *IoConn, res: i32) !void {
    if (res <= 0) {
        conn.deinit();
        return;
    }
    conn.write_sent += @intCast(res);
    if (conn.write_sent < conn.write_len) {
        // Partial send — submit the remainder.
        return submitSend(ring, conn);
    }
    // Drain finished — reset the buffer.
    conn.write_sent = 0;
    conn.write_len = 0;
    if (conn.close_after_send) {
        conn.deinit();
        return;
    }
    // We may have already buffered the next request's bytes during the previous
    // recv (HTTP pipelining). Try to make progress on those before issuing a
    // fresh recv.
    if (conn.input_len > 0) {
        const action = processRequests(conn);
        switch (action) {
            .need_more_data => return submitRecv(ring, conn),
            .send_then_close => {
                conn.close_after_send = true;
                return submitSend(ring, conn);
            },
            .send_then_recv => return submitSend(ring, conn),
            .close => {
                conn.deinit();
                return;
            },
        }
    }
    return submitRecv(ring, conn);
}

const Action = enum {
    need_more_data,
    send_then_recv,
    send_then_close,
    close,
};

/// Drain as many requests out of the input buffer as we can, building responses
/// into the connection's write buffer. Mirrors `Connection.handleReadable` from
/// the kqueue path but stops short of actually invoking `send` (the io_uring
/// loop does that asynchronously).
fn processRequests(conn: *IoConn) Action {
    var any_close = false;
    while (conn.input_len > 0) {
        const parsed = server_mod.parseRequestHead(conn.inputBytes(), conn.headers) catch |err| switch (err) {
            error.IncompleteRequestHead => {
                if (conn.write_len > 0) return .send_then_recv;
                return .need_more_data;
            },
            else => {
                if (conn.write_len > 0) return .send_then_close;
                return .close;
            },
        };

        if (parsed.body.len < parsed.content_length and parsed.body_start + parsed.content_length <= conn.inputCapacity()) {
            if (conn.write_len > 0) return .send_then_recv;
            return .need_more_data;
        }
        if (parsed.body.len < parsed.content_length) {
            // Body bigger than the input buffer — protocol error in this MVP.
            if (conn.write_len > 0) return .send_then_close;
            return .close;
        }

        // ---- Static-dispatch shortcut ----
        var dispatched = false;
        static_dispatch: {
            if (parsed.content_length != 0) break :static_dispatch;
            if (conn.server.app.middlewares.items.len != 0) break :static_dispatch;
            if (parsed.is_head) break :static_dispatch;
            const static_bytes = conn.server.app.router.tryStaticDispatch(parsed.method, parsed.path) orelse break :static_dispatch;
            if (!conn.appendStaticBytes(static_bytes)) {
                // No room in write buffer — flush what we have and come back.
                return .send_then_recv;
            }
            dispatched = true;
        }

        if (!dispatched) {
            const req_allocator = conn.arena.allocator();
            const body_bytes = parsed.body[0..parsed.content_length];
            var req = request.Request.initPartsCached(
                req_allocator,
                parsed.method,
                parsed.target,
                parsed.path,
                parsed.query_string,
                parsed.headers,
                body_bytes,
                parsed.header_cache,
            );

            var res = conn.server.app.handle(&req) catch {
                _ = conn.arena.reset(.retain_capacity);
                if (conn.write_len > 0) return .send_then_close;
                return .close;
            };

            if (server_mod.canUseFastJsonBytes(&res, parsed.keep_alive, parsed.send_keep_alive_header, parsed.is_head)) {
                if (!conn.appendFastJsonBytes(res.body)) {
                    _ = conn.arena.reset(.retain_capacity);
                    return .send_then_recv;
                }
            } else {
                // Non-fast-path response: flush our batched fast-path bytes (if any),
                // then fall back to a synchronous send for this single response. This
                // doesn't get io_uring batching but still works for file/stream/custom-
                // header responses.
                if (conn.write_len > 0) {
                    blockingSendAll(conn.fd, conn.pendingWrite()) catch {
                        _ = conn.arena.reset(.retain_capacity);
                        return .close;
                    };
                    conn.write_len = 0;
                    conn.write_sent = 0;
                }
                server_mod.sendResponse(conn.fd, &res, parsed.keep_alive, parsed.send_keep_alive_header, parsed.is_head) catch {
                    _ = conn.arena.reset(.retain_capacity);
                    return .close;
                };
            }
            _ = conn.arena.reset(.retain_capacity);
        }

        conn.consume(parsed.consumed_len);
        if (!parsed.keep_alive) {
            any_close = true;
            break;
        }
    }

    if (conn.write_len > 0) {
        return if (any_close) .send_then_close else .send_then_recv;
    }
    if (any_close) return .close;
    return .need_more_data;
}
fn blockingSendAll(fd: linux.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            // -EINTR == -4 on every supported Linux ABI; retry on it, fail on anything else.
            if (signed == -4) continue;
            return error.SendFailed;
        }
        if (rc == 0) return error.SendFailed;
        written += rc;
    }
}

fn configureAcceptedSocket(fd: linux.fd_t) void {
    const enabled: c_int = 1;
    posix.setsockopt(
        fd,
        posix.IPPROTO.TCP,
        posix.TCP.NODELAY,
        std.mem.asBytes(&enabled),
    ) catch {};
}
