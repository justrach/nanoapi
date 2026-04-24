const std = @import("std");

pub const TaskFn = *const fn (ctx: *anyopaque) anyerror!void;

pub const Task = struct {
    ctx: *anyopaque,
    run: TaskFn,
};

pub const BackgroundTasks = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task) = .empty,

    pub fn init(allocator: std.mem.Allocator) BackgroundTasks {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BackgroundTasks) void {
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addTask(self: *BackgroundTasks, ctx: *anyopaque, run: TaskFn) !void {
        try self.tasks.append(self.allocator, .{ .ctx = ctx, .run = run });
    }

    pub fn runTasks(self: *BackgroundTasks) !void {
        for (self.tasks.items) |task| try task.run(task.ctx);
    }
};
