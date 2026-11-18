// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Job entry points for the UI. One job at a time, no global state beyond the cancel flag.

const std = @import("std");
const source = @import("source.zig");
const plan_mod = @import("plan.zig");
const exporter = @import("export.zig");
const folder = @import("folder.zig");
const extractor = @import("extract.zig");
const pieces = @import("pieces.zig");

pub const Progress = struct {
    done: u64,
    total: u64,
    current: []const u8,
};

pub const ProgressFn = *const fn (ctx: ?*anyopaque, progress: Progress) void;

var cancel_flag = std.atomic.Value(bool).init(false);

var progress_fn: ?ProgressFn = null;
var progress_ctx: ?*anyopaque = null;

pub fn cancel() void {
    cancel_flag.store(true, .release);
}

fn report(_: ?*anyopaque, progress: exporter.Progress) void {
    if (progress_fn) |callback| callback(progress_ctx, .{
        .done = progress.done,
        .total = progress.total,
        .current = progress.current,
    });
}

/// Job mode. AUTO groups a piece set when the names say so, otherwise one input converts and
/// two inputs merge. MERGE forces base + update. SINGLE treats every input as one piece set.
pub const Mode = enum(c_int) {
    auto = 0,
    merge = 1,
    single = 2,
};

/// Output kind: a `.zar` archive, or an extracted folder tree.
pub const Kind = enum(c_int) {
    archive = 0,
    extract = 1,
};

/// Outcome of one job. `failed` and `cancelled` carry a message written into the caller's buffer.
pub const Outcome = enum { ok, failed, cancelled };

/// Runs one convert or merge job and writes a user-facing message into `err` on failure.
pub fn run(
    mode: Mode,
    kind: Kind,
    allow_overwrite: bool,
    output: []const u8,
    inputs: []const []const u8,
    callback: ?ProgressFn,
    ctx: ?*anyopaque,
    err: []u8,
) Outcome {
    cancel_flag.store(false, .release);
    progress_fn = callback;
    progress_ctx = ctx;

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (inputs.len == 0) {
        writeMessage(err, "select one pkg to convert, or a base and an update to merge");
        return .failed;
    }

    const paths = inputs;
    const grouped = switch (mode) {
        .single => true,
        .merge => false,
        .auto => pieces.looksLikeSet(paths),
    };
    const source_count: usize = if (grouped) 1 else inputs.len;
    if (!grouped and inputs.len > 2) {
        writeMessage(err, "select at most two pkgs: a base and an update");
        return .failed;
    }

    var sources: [2]source.Source = undefined;
    var opened: usize = 0;
    defer for (sources[0..opened]) |s| s.close();

    if (grouped) {
        const result = source.Source.open(io, arena, paths) catch {
            writeMessage(err, "out of memory");
            return .failed;
        };
        switch (result) {
            .ok => |src| {
                sources[0] = src;
                opened = 1;
            },
            .fail => |fail| {
                var buf: [512]u8 = undefined;
                writeMessage(err, source.describe(fail, &buf));
                return .failed;
            },
        }
    }
    if (!grouped) {
        for (paths, 0..) |path, i| {
            const result = source.Source.open(io, arena, &.{path}) catch {
                writeMessage(err, "out of memory");
                return .failed;
            };
            switch (result) {
                .ok => |src| {
                    sources[i] = src;
                    opened += 1;
                },
                .fail => |fail| {
                    var buf: [512]u8 = undefined;
                    writeMessage(err, source.describe(fail, &buf));
                    return .failed;
                },
            }
        }
    }

    var base_identity = plan_mod.Identity.fromSource(&sources[0]);
    var update_identity = if (source_count == 2) plan_mod.Identity.fromSource(&sources[1]) else null;
    var swapped = false;
    if (update_identity) |upd| {
        if (plan_mod.shouldSwapRoles(base_identity, upd)) {
            std.mem.swap(source.Source, &sources[0], &sources[1]);
            base_identity = upd;
            update_identity = plan_mod.Identity.fromSource(&sources[1]);
            swapped = true;
        }
    }
    if (plan_mod.preflight(base_identity, update_identity)) |failure| {
        var buf: [512]u8 = undefined;
        writeMessage(err, plan_mod.describe(failure, &buf));
        return .failed;
    }

    const plan = plan_mod.build(arena, sources[0..source_count]) catch {
        writeMessage(err, "out of memory");
        return .failed;
    };

    switch (kind) {
        .archive => {
            _ = exporter.run(arena, io, sources[0..source_count], &plan, .{
                .output = output,
                .overwrite = allow_overwrite,
                .cancel = &cancel_flag,
                .on_progress = report,
            }) catch |failure| return failureCode(err, failure, exporter.reasonName);
        },
        .extract => {
            _ = extractor.run(arena, io, sources[0..source_count], &plan, .{
                .output = output,
                .overwrite = allow_overwrite,
                .cancel = &cancel_flag,
                .on_progress = report,
            }) catch |failure| return failureCode(err, failure, extractor.reasonName);
        },
    }
    if (swapped) {
        writeMessage(err, "note: inputs were swapped, the update was listed first");
    }
    return .ok;
}

/// Archives an already extracted folder. Same cancel flag and progress path as `run`.
pub fn runFolder(
    allow_overwrite: bool,
    output: []const u8,
    roots: []const []const u8,
    callback: ?ProgressFn,
    ctx: ?*anyopaque,
    err: []u8,
) Outcome {
    cancel_flag.store(false, .release);
    progress_fn = callback;
    progress_ctx = ctx;

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    _ = folder.runRoots(arena_state.allocator(), threaded.io(), roots, .{
        .output = output,
        .overwrite = allow_overwrite,
        .cancel = &cancel_flag,
        .on_progress = report,
    }) catch |failure| {
        writeMessage(err, folder.reasonName(failure));
        return if (failure == error.Cancelled) .cancelled else .failed;
    };
    return .ok;
}

fn failureCode(buffer: []u8, failure: anyerror, comptime reasonName: anytype) Outcome {
    if (failure == error.OutOfMemory) {
        writeMessage(buffer, "out of memory");
        return .failed;
    }
    if (failure == error.Cancelled) {
        writeMessage(buffer, reasonName(error.Cancelled));
        return .cancelled;
    }
    writeMessage(buffer, reasonName(@errorCast(failure)));
    return .failed;
}

/// Copies `message` into the caller's buffer, NUL-terminated and truncated to fit.
fn writeMessage(buffer: []u8, message: []const u8) void {
    if (buffer.len == 0) return;
    const n = @min(buffer.len - 1, message.len);
    @memcpy(buffer[0..n], message[0..n]);
    buffer[n] = 0;
}

test "integration: run converts one pkg and reports progress" {
    const path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;

    const output = ".zig-cache/p2z-bridge-test.zar";
    std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, output ++ ".part") catch {};

    var err: [256]u8 = @splat(0);
    TestProgress.last_done = 0;

    const inputs = [_][]const u8{path};
    const outcome = run(.single, .archive, false, output, &inputs, TestProgress.cb, null, &err);
    try std.testing.expectEqual(Outcome.ok, outcome);
    try std.testing.expect(TestProgress.last_done > 0);
    try std.testing.expect(exists(output));
}

const TestProgress = struct {
    var last_done: u64 = 0;
    fn cb(_: ?*anyopaque, progress: Progress) void {
        last_done = progress.done;
    }
};

fn exists(path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch return false;
    file.close(std.testing.io);
    return true;
}

test "integration: runFolder archives a folder and reports a missing one" {
    const io = std.testing.io;

    const dir = ".zig-cache/p2z-bridge-folder";
    const out = ".zig-cache/p2z-bridge-folder.zar";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const src = try std.Io.Dir.cwd().createFile(io, dir ++ "/hello.txt", .{});
    try src.writeStreamingAll(io, "hello\n");
    src.close(io);

    var err: [256]u8 = @splat(0);
    TestProgress.last_done = 0;
    const roots = [_][]const u8{dir};
    try std.testing.expectEqual(Outcome.ok, runFolder(false, out, &roots, TestProgress.cb, null, &err));
    try std.testing.expect(exists(out));
    try std.testing.expect(TestProgress.last_done > 0);

    const none = [_][]const u8{".zig-cache/p2z-bridge-no-folder"};
    const missing = runFolder(false, out ++ ".x", &none, null, null, &err);
    try std.testing.expectEqual(Outcome.failed, missing);
    try std.testing.expect(std.mem.indexOf(u8, &err, "not a readable directory") != null);
}

test "integration: merge accepts the update listed first" {
    const base_path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;
    const update_path = if (std.c.getenv("P2Z_TEST_UPDATE")) |p| std.mem.span(p) else return error.SkipZigTest;

    const output = ".zig-cache/p2z-bridge-swap.zar";
    std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};

    // Update first on purpose: the roles must be detected, not taken from the order.
    const inputs = [_][]const u8{ update_path, base_path };
    var err: [256]u8 = @splat(0);
    const outcome = run(.auto, .archive, false, output, &inputs, null, null, &err);
    try std.testing.expectEqual(Outcome.ok, outcome);
    try std.testing.expect(std.mem.indexOf(u8, &err, "swapped") != null);
    try std.testing.expect(exists(output));
}
