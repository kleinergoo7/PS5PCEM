// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Extracts a plan into a directory tree. Writes `<out>.part`, verifies every file size, then
//! replaces the destination. Cancel and every failure delete the partial tree.

const std = @import("std");
const plan_mod = @import("plan.zig");
const source = @import("source.zig");
const pfs = @import("pfs.zig");
const pkg = @import("pkg.zig");
const export_mod = @import("export.zig");

pub const Progress = export_mod.Progress;
pub const Callback = export_mod.Callback;

pub const Error = error{
    OutputExists,
    BackupExists,
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
        error.OutputExists => "output folder already exists",
        error.BackupExists => "a previous .old folder is still there, remove it first",
        error.Cancelled => "cancelled",
        error.CreateFailed => "cannot create the output folder",
        error.WriteFailed => "cannot write an extracted file",
        error.VerifyFailed => "an extracted file has the wrong size or is missing",
        error.RenameFailed => "cannot move the finished folder into place",
        error.ReadFailed => "cannot read a source pkg",
        error.OutOfMemory => "out of memory",
    };
}

pub const Options = struct {
    output: []const u8,
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
) Error!Stats {
    const part = std.fmt.allocPrint(arena, "{s}.part", .{options.output}) catch return error.OutOfMemory;
    const backup = std.fmt.allocPrint(arena, "{s}.old", .{options.output}) catch return error.OutOfMemory;

    const exists = pathExists(io, options.output);
    if (exists and !options.overwrite) return error.OutputExists;
    if (exists and pathExists(io, backup)) return error.BackupExists;

    // A leftover .part from an interrupted run is ours to remove.
    std.Io.Dir.cwd().deleteTree(io, part) catch {};
    std.Io.Dir.cwd().createDirPath(io, part) catch return error.CreateFailed;
    errdefer std.Io.Dir.cwd().deleteTree(io, part) catch {};

    var done: u64 = 0;
    const total = plan.total_bytes;
    var current: []const u8 = "";
    const buffer = arena.alloc(u8, chunk_size) catch return error.OutOfMemory;

    for (plan.items) |item| {
        if (options.cancel.load(.acquire)) return error.Cancelled;
        current = item.path;
        report(options, done, total, current);

        const target = std.fmt.allocPrint(arena, "{s}/{s}", .{ part, item.path }) catch return error.OutOfMemory;
        switch (item.kind) {
            .pfs_dir => std.Io.Dir.cwd().createDirPath(io, target) catch return error.CreateFailed,
            .pkg_entry => {
                const entry = item.entry.?;
                const src = &sources[item.source_index];
                const file = std.Io.Dir.cwd().createFile(io, target, .{}) catch return error.CreateFailed;
                defer file.close(io);
                if (pkg.entryNeedsDecryption(entry.id)) {
                    const data = src.sceEntryData(entry) catch return error.ReadFailed;
                    file.writeStreamingAll(io, data) catch return error.WriteFailed;
                    done += data.len;
                    report(options, done, total, current);
                    continue;
                }
                var offset: u64 = 0;
                while (offset < entry.size) {
                    if (options.cancel.load(.acquire)) return error.Cancelled;
                    const take: usize = @intCast(@min(chunk_size, entry.size - offset));
                    src.stream.readExact(io, entry.offset + offset, buffer[0..take]) catch return error.ReadFailed;
                    file.writeStreamingAll(io, buffer[0..take]) catch return error.WriteFailed;
                    offset += take;
                    done += take;
                    report(options, done, total, current);
                }
            },
            .pfs_file => {
                const entry = item.pfs_entry.?;
                const src = &sources[item.source_index];
                const file = std.Io.Dir.cwd().createFile(io, target, .{}) catch return error.CreateFailed;
                defer file.close(io);
                var written: u64 = 0;
                var block: [pfs.block_size]u8 = undefined;
                var block_index: usize = entry.loc;
                while (written < entry.size) {
                    if (options.cancel.load(.acquire)) return error.Cancelled;
                    const data = src.readPfsBlock(block_index, &block) catch return error.ReadFailed;
                    const take: usize = @intCast(@min(data.len, entry.size - written));
                    file.writeStreamingAll(io, data[0..take]) catch return error.WriteFailed;
                    written += take;
                    done += take;
                    block_index += 1;
                    report(options, done, total, current);
                }
            },
        }
    }

    try verify(io, arena, part, plan);

    if (exists) {
        std.Io.Dir.rename(std.Io.Dir.cwd(), options.output, std.Io.Dir.cwd(), backup, io) catch
            return error.RenameFailed;
    }
    std.Io.Dir.rename(std.Io.Dir.cwd(), part, std.Io.Dir.cwd(), options.output, io) catch {
        if (exists) std.Io.Dir.rename(std.Io.Dir.cwd(), backup, std.Io.Dir.cwd(), options.output, io) catch {};
        return error.RenameFailed;
    };
    if (exists) std.Io.Dir.cwd().deleteTree(io, backup) catch {};

    return .{ .files = plan.file_count, .dirs = plan.dir_count, .bytes = plan.total_bytes };
}

fn verify(io: std.Io, arena: std.mem.Allocator, root: []const u8, plan: *const plan_mod.Plan) Error!void {
    for (plan.items) |item| {
        const target = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, item.path }) catch return error.OutOfMemory;
        const expected: u64 = switch (item.kind) {
            .pfs_dir => continue,
            .pkg_entry => item.entry.?.size,
            .pfs_file => item.pfs_entry.?.size,
        };
        const stat = std.Io.Dir.cwd().statFile(io, target, .{}) catch {
            std.debug.print("verify: missing {s}\\n", .{item.path});
            return error.VerifyFailed;
        };
        if (stat.size != expected) {
            std.debug.print("verify: {s} is {d} bytes, expected {d}\\n", .{ item.path, stat.size, expected });
            return error.VerifyFailed;
        }
    }
}

fn pathExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    _ = stat;
    return true;
}

fn report(options: Options, done: u64, total: u64, current: []const u8) void {
    if (options.on_progress) |callback| callback(options.ctx, .{ .done = done, .total = total, .current = current });
}

test "integration: extract writes a verified tree, cancel leaves nothing" {
    const path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = ".zig-cache/p2z-extract-test";
    defer std.Io.Dir.cwd().deleteTree(io, out) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out ++ ".part") catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out ++ ".old") catch {};

    const result = try source.Source.open(io, arena, &.{path});
    const src = switch (result) {
        .ok => |s| s,
        .fail => return error.UnexpectedFailure,
    };
    defer src.close();

    var sources = [_]source.Source{src};
    const the_plan = try plan_mod.build(arena, &sources);

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, run(arena, io, &sources, &the_plan, .{
        .output = out,
        .cancel = &cancelled,
    }));
    try std.testing.expect(!pathExists(io, out));

    cancelled.store(false, .release);
    const stats = try run(arena, io, &sources, &the_plan, .{ .output = out, .cancel = &cancelled });
    try std.testing.expectEqual(the_plan.file_count, stats.files);
    try std.testing.expect(pathExists(io, out));
    try std.testing.expect(!pathExists(io, out ++ ".part"));
    try std.testing.expect(pathExists(io, out ++ "/eboot.bin"));
    const sfo = try std.Io.Dir.cwd().statFile(io, out ++ "/sce_sys/param.sfo", .{});
    try std.testing.expect(sfo.size > 0);

    // Replace an existing tree: the new one lands, no backup stays behind.
    _ = try run(arena, io, &sources, &the_plan, .{ .output = out, .overwrite = true, .cancel = &cancelled });
    try std.testing.expect(!pathExists(io, out ++ ".old"));
}
