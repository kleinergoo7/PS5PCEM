// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Streams a plan into a `.zar.part` file, verifies it by reopening, and only then renames.
//! Cancel and every failure remove the partial file.

const std = @import("std");
const plan_mod = @import("plan.zig");
const pkg = @import("pkg.zig");
const source = @import("source.zig");
const zar = @import("zar.zig");
const pfs = @import("pfs.zig");

pub const Error = error{
    OutputExists,
    Cancelled,
    CreateFailed,
    WriteFailed,
    VerifyFailed,
    RenameFailed,
    ReadFailed,
    OutOfMemory,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.OutputExists => "output file already exists",
        error.Cancelled => "cancelled",
        error.CreateFailed => "cannot create the output file",
        error.WriteFailed => "cannot write the output file",
        error.VerifyFailed => "the written archive did not verify",
        error.RenameFailed => "cannot rename the finished archive",
        error.ReadFailed => "cannot read a source pkg",
        error.OutOfMemory => "out of memory",
    };
}

pub const Progress = struct {
    done: u64,
    total: u64,
    /// Path of the entry currently being written. Not NUL-terminated.
    current: []const u8,
};

pub const Callback = *const fn (ctx: ?*anyopaque, progress: Progress) void;

pub const Options = struct {
    output: []const u8,
    /// When false, an existing output is refused. When true the finished archive replaces it
    /// atomically after verification, so a failed run leaves the old file intact.
    overwrite: bool = false,
    cancel: *const std.atomic.Value(bool),
    on_progress: ?Callback = null,
    ctx: ?*anyopaque = null,
};

pub const Stats = struct {
    files: usize,
    dirs: usize,
    bytes: u64,
};

const chunk_size: usize = 256 * 1024;

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    sources: []const source.Source,
    plan: *const plan_mod.Plan,
    options: Options,
) !Stats {
    if (!options.overwrite and fileExists(io, options.output)) return error.OutputExists;

    const part_path = try std.fmt.allocPrint(arena, "{s}.part", .{options.output});
    defer std.Io.Dir.cwd().deleteFile(io, part_path) catch {};

    const dir = std.Io.Dir.cwd();
    const file = dir.createFile(io, part_path, .{}) catch return error.CreateFailed;
    var closed = false;
    defer if (!closed) file.close(io);

    var writer = zar.Writer.init(io, file, arena) catch return error.WriteFailed;

    var done: u64 = 0;
    var current: []const u8 = "";
    const total = plan.total_bytes;
    var buffer = arena.alloc(u8, chunk_size) catch return error.OutOfMemory;

    for (plan.items) |item| {
        if (options.cancel.load(.acquire)) return error.Cancelled;
        current = item.path;
        report(options, done, total, current);
        switch (item.kind) {
            .pfs_dir => writer.makeDir(item.path) catch return error.WriteFailed,
            .pkg_entry => {
                const entry = item.entry.?;
                const src = &sources[item.source_index];
                writer.startFile(item.path) catch return error.WriteFailed;
                if (pkg.entryNeedsDecryption(entry.id)) {
                    const data = src.sceEntryData(entry) catch return error.ReadFailed;
                    writer.appendData(data) catch return error.WriteFailed;
                    done += data.len;
                    report(options, done, total, current);
                    continue;
                }
                var offset: u64 = 0;
                while (offset < entry.size) {
                    if (options.cancel.load(.acquire)) return error.Cancelled;
                    const take: usize = @intCast(@min(chunk_size, entry.size - offset));
                    src.stream.readExact(io, entry.offset + offset, buffer[0..take]) catch return error.ReadFailed;
                    writer.appendData(buffer[0..take]) catch return error.WriteFailed;
                    offset += take;
                    done += take;
                    report(options, done, total, current);
                }
            },
            .pfs_file => {
                const entry = item.pfs_entry.?;
                const src = &sources[item.source_index];
                writer.startFile(item.path) catch return error.WriteFailed;
                var written: u64 = 0;
                var block: [pfs.block_size]u8 = undefined;
                var block_index: usize = entry.loc;
                while (written < entry.size) {
                    if (options.cancel.load(.acquire)) return error.Cancelled;
                    const data = src.readPfsBlock(block_index, &block) catch return error.ReadFailed;
                    const take: usize = @intCast(@min(data.len, entry.size - written));
                    writer.appendData(data[0..take]) catch return error.WriteFailed;
                    written += take;
                    done += take;
                    block_index += 1;
                    report(options, done, total, current);
                }
            },
        }
    }

    writer.finalize() catch return error.WriteFailed;
    file.close(io);
    closed = true;

    verify(io, arena, part_path, plan) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print("verify failed: {t}\n", .{err});
            return error.VerifyFailed;
        },
    };

    std.Io.Dir.rename(std.Io.Dir.cwd(), part_path, std.Io.Dir.cwd(), options.output, io) catch return error.RenameFailed;

    return .{
        .files = plan.file_count,
        .dirs = plan.dir_count,
        .bytes = plan.total_bytes,
    };
}

fn verify(io: std.Io, arena: std.mem.Allocator, path: []const u8, plan: *const plan_mod.Plan) Error!void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.VerifyFailed;
    defer file.close(io);
    var reader = zar.Reader.open(io, file, arena) catch return error.VerifyFailed;
    const entries = reader.entries() catch return error.VerifyFailed;

    var files: usize = 0;
    var dirs: usize = 0;
    for (entries) |entry| {
        if (entry.is_file) files += 1 else dirs += 1;
    }
    if (files != plan.file_count or dirs != plan.dir_count) {
        std.debug.print("verify: files {d}/{d} dirs {d}/{d}\n", .{ files, plan.file_count, dirs, plan.dir_count });
        return error.VerifyFailed;
    }

    var index = std.StringHashMapUnmanaged(u64).empty;
    for (entries) |entry| {
        const key = lower(arena, entry.path) catch return error.OutOfMemory;
        index.put(arena, key, if (entry.is_file) entry.size else 0) catch return error.OutOfMemory;
    }
    for (plan.items) |item| {
        const key = lower(arena, item.path) catch return error.OutOfMemory;
        const expected: u64 = switch (item.kind) {
            .pfs_dir => 0,
            .pkg_entry => item.entry.?.size,
            .pfs_file => item.pfs_entry.?.size,
        };
        const actual = index.get(key) orelse {
            std.debug.print("verify: missing {s}\n", .{item.path});
            return error.VerifyFailed;
        };
        if (actual != expected) {
            std.debug.print("verify: size {s}: {d} != {d}\n", .{ item.path, actual, expected });
            return error.VerifyFailed;
        }
    }
}

fn lower(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn report(options: Options, done: u64, total: u64, current: []const u8) void {
    if (options.on_progress) |callback| callback(options.ctx, .{ .done = done, .total = total, .current = current });
}

test "integration: export verifies and cancel leaves nothing behind" {
    const path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = ".zig-cache/p2z-export-test.zar";
    const part = out ++ ".part";
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, part) catch {};

    const result = try source.Source.open(io, arena, &.{path});
    const src = switch (result) {
        .ok => |s| s,
        .fail => return error.UnexpectedFailure,
    };
    defer src.close();

    var sources = [_]source.Source{src};
    const the_plan = try plan_mod.build(arena, &sources);

    // Cancel before the first byte: no output, no partial file.
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, run(arena, io, &sources, &the_plan, .{
        .output = out,
        .cancel = &cancelled,
    }));
    try std.testing.expectEqual(false, fileExists(io, out));
    try std.testing.expectEqual(false, fileExists(io, part));

    // Now let it run: the archive appears and verifies.
    cancelled.store(false, .release);
    const stats = try run(arena, io, &sources, &the_plan, .{ .output = out, .cancel = &cancelled });
    try std.testing.expectEqual(the_plan.file_count, stats.files);
    try std.testing.expect(fileExists(io, out));
    try std.testing.expectEqual(false, fileExists(io, part));

    // Refuses to overwrite.
    try std.testing.expectError(error.OutputExists, run(arena, io, &sources, &the_plan, .{
        .output = out,
        .cancel = &cancelled,
    }));
}
