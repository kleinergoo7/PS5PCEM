// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Streams one or two extracted folders into a `.zar.part`, verifies it by reopening, and only
//! then renames. Later roots win on the same path, which is how a base folder and an update
//! folder merge. Same contract as export.zig: cancel and every failure remove the partial file.

const std = @import("std");
const builtin = @import("builtin");
const exporter = @import("export.zig");
const zar = @import("zar.zig");

pub const Options = exporter.Options;
pub const Progress = exporter.Progress;
pub const Stats = exporter.Stats;

pub const Error = error{
    OutputExists,
    Cancelled,
    CreateFailed,
    WriteFailed,
    VerifyFailed,
    RenameFailed,
    ReadFailed,
    OutOfMemory,
    NotADirectory,
    UnsupportedEntry,
    DuplicateEntry,
    PathConflict,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.OutputExists => "output file already exists",
        error.Cancelled => "cancelled",
        error.CreateFailed => "cannot create the output file",
        error.WriteFailed => "cannot write the output file",
        error.VerifyFailed => "the written archive did not verify",
        error.RenameFailed => "cannot rename the finished archive",
        error.ReadFailed => "cannot read the input folder",
        error.OutOfMemory => "out of memory",
        error.NotADirectory => "the input is not a readable directory",
        error.UnsupportedEntry => "the folder holds a symlink or special file; only regular files and directories can be archived",
        error.DuplicateEntry => "two entries differ only in letter case; .zar names are case-insensitive",
        error.PathConflict => "a file and a directory share a path",
    };
}

const chunk_size: usize = 256 * 1024;

const Totals = struct { files: usize, dirs: usize, bytes: u64 };

/// One folder, archived as it is.
pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    options: Options,
) Error!Stats {
    const roots = [_][]const u8{root_path};
    return runRoots(arena, io, &roots, options);
}

/// Several folders in priority order: a later root replaces a file of an earlier one.
pub fn runRoots(
    arena: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    options: Options,
) Error!Stats {
    if (roots.len == 0 or roots.len > 2) return error.NotADirectory;
    if (!options.overwrite and fileExists(io, options.output)) return error.OutputExists;

    var dirs: [2]std.Io.Dir = undefined;
    var opened: usize = 0;
    defer for (dirs[0..opened]) |dir| dir.close(io);
    for (roots, 0..) |root_path, i| {
        dirs[i] = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch
            return error.NotADirectory;
        opened += 1;
    }

    // Resolving the effective tree first gives an exact progress total and rejects an
    // unsupported entry before a .part file exists.
    const items = try collect(arena, io, roots, dirs[0..opened]);
    var totals: Totals = .{ .files = 0, .dirs = 0, .bytes = 0 };
    for (items) |item| {
        if (item.is_dir) {
            totals.dirs += 1;
        } else {
            totals.files += 1;
            totals.bytes += item.size;
        }
    }

    const part_path = std.fmt.allocPrint(arena, "{s}.part", .{options.output}) catch
        return error.OutOfMemory;
    defer std.Io.Dir.cwd().deleteFile(io, part_path) catch {};

    const file = std.Io.Dir.cwd().createFile(io, part_path, .{}) catch return error.CreateFailed;
    var closed = false;
    defer if (!closed) file.close(io);

    var writer = zar.Writer.init(io, file, arena) catch |err| return writerError(err);

    const buffer = arena.alloc(u8, chunk_size) catch return error.OutOfMemory;
    var done: u64 = 0;

    // Directories first, then files, each in first-seen order: the same archive for the same
    // input, and no reliance on the writer creating missing parents.
    for ([_]bool{ true, false }) |want_dir| {
        for (items) |item| {
            if (item.is_dir != want_dir) continue;
            if (options.cancel.load(.acquire)) return error.Cancelled;
            report(options, done, totals.bytes, item.path);

            if (item.is_dir) {
                writer.makeDir(item.path) catch |err| return writerError(err);
                continue;
            }

            const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ roots[item.root_index], item.path }) catch
                return error.OutOfMemory;
            const src = std.Io.Dir.cwd().openFile(io, full, .{}) catch return error.ReadFailed;
            defer src.close(io);
            // A file that changed between the scan and this read would silently truncate.
            const size = src.length(io) catch return error.ReadFailed;
            if (size != item.size) {
                std.debug.print("folder: {s} changed size during the run\n", .{item.path});
                return error.ReadFailed;
            }

            writer.startFile(item.path) catch |err| return writerError(err);
            var offset: u64 = 0;
            while (offset < size) {
                if (options.cancel.load(.acquire)) return error.Cancelled;
                const take: usize = @intCast(@min(chunk_size, size - offset));
                const read = src.readPositionalAll(io, buffer[0..take], offset) catch
                    return error.ReadFailed;
                if (read != take) return error.ReadFailed;
                writer.appendData(buffer[0..take]) catch |err| return writerError(err);
                offset += take;
                done += take;
                report(options, done, totals.bytes, item.path);
            }
        }
    }

    writer.finalize() catch |err| return writerError(err);
    file.close(io);
    closed = true;

    verify(io, arena, part_path, items) catch |err| {
        std.debug.print("verify failed: {t}\n", .{err});
        return error.VerifyFailed;
    };

    std.Io.Dir.rename(std.Io.Dir.cwd(), part_path, std.Io.Dir.cwd(), options.output, io) catch
        return error.RenameFailed;

    return .{ .files = totals.files, .dirs = totals.dirs, .bytes = totals.bytes };
}

const Item = struct {
    /// Path inside the archive, `/` separated.
    path: []const u8,
    is_dir: bool,
    size: u64,
    /// Which root the winning version comes from.
    root_index: usize,
};

fn collect(
    arena: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    dirs: []std.Io.Dir,
) Error![]Item {
    _ = roots;
    var list = std.ArrayList(Item).empty;
    var by_path = std.StringHashMapUnmanaged(usize).empty;

    for (dirs, 0..) |root, root_index| {
        var walker = root.walk(arena) catch |err| return walkError(err);
        defer walker.deinit();
        while (true) {
            const entry = walker.next(io) catch |err| return walkError(err);
            if (entry == null) break;
            const found = entry.?;

            // Windows hands back backslash paths; the archive stores components only, and the
            // verification compares against what was written, so normalise once here.
            const rel = try archivePath(arena, found.path);
            const is_dir = found.kind == .directory;
            if (!is_dir and found.kind != .file) {
                std.debug.print("folder: {s} is not a regular file or directory\n", .{found.path});
                return error.UnsupportedEntry;
            }

            const size: u64 = if (is_dir) 0 else blk: {
                const file = found.dir.openFile(io, found.basename, .{}) catch return error.ReadFailed;
                defer file.close(io);
                break :blk file.length(io) catch return error.ReadFailed;
            };

            const lower = try lowerDup(arena, rel);
            if (by_path.get(lower)) |index| {
                if (list.items[index].is_dir != is_dir) {
                    std.debug.print("folder: {s} is a file in one input and a directory in the other\n", .{rel});
                    return error.PathConflict;
                }
                // A later root replaces an earlier one.
                list.items[index].size = size;
                list.items[index].root_index = root_index;
            } else {
                by_path.put(arena, lower, list.items.len) catch return error.OutOfMemory;
                list.append(arena, .{
                    .path = rel,
                    .is_dir = is_dir,
                    .size = size,
                    .root_index = root_index,
                }) catch return error.OutOfMemory;
            }
        }
    }
    return list.toOwnedSlice(arena);
}

fn verify(io: std.Io, arena: std.mem.Allocator, path: []const u8, items: []const Item) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.VerifyFailed;
    defer file.close(io);
    var reader = zar.Reader.open(io, file, arena) catch return error.VerifyFailed;
    const entries = reader.entries() catch return error.VerifyFailed;

    if (entries.len != items.len) {
        std.debug.print("verify: {d} entries, expected {d}\n", .{ entries.len, items.len });
        return error.VerifyFailed;
    }
    for (items) |want| {
        var found = false;
        for (entries) |got| {
            if (!std.mem.eql(u8, got.path, want.path)) continue;
            found = true;
            if (got.is_file == want.is_dir or (!want.is_dir and got.size != want.size)) {
                std.debug.print("verify: {s}: got {d} bytes, expected {d}\n", .{ want.path, got.size, want.size });
                return error.VerifyFailed;
            }
            break;
        }
        if (!found) {
            std.debug.print("verify: missing {s}\n", .{want.path});
            return error.VerifyFailed;
        }
    }
}

fn archivePath(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    const copy = arena.dupe(u8, path) catch return error.OutOfMemory;
    _ = std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

fn lowerDup(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    const copy = arena.dupe(u8, path) catch return error.OutOfMemory;
    for (copy) |*c| c.* = std.ascii.toLower(c.*);
    return copy;
}

fn writerError(err: zar.Error) Error {
    return switch (err) {
        error.DuplicateEntry, error.NotAFile => error.DuplicateEntry,
        error.PathNotFound => error.PathConflict,
        error.OutOfMemory => error.OutOfMemory,
        error.WriteFailed, error.CompressionFailed => error.WriteFailed,
    };
}

fn walkError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.ReadFailed;
}

fn report(options: Options, done: u64, total: u64, current: []const u8) void {
    if (options.on_progress) |callback| callback(options.ctx, .{ .done = done, .total = total, .current = current });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn makeTree(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const root = ".zig-cache/p2z-folder-src";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sub/deep");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/empty");
    try writeFile(io, root ++ "/a.txt", "alpha\n");
    try writeFile(io, root ++ "/sub/b.bin", "beta\n");
    // Larger than one 64 KiB block, so the writer takes the multi-block path.
    const big = try arena.alloc(u8, 70_000);
    for (big, 0..) |*byte, i| byte.* = @truncate(i * 7 + 3);
    try writeFile(io, root ++ "/sub/deep/c.bin", big);
    return root;
}

test "folder: archive paths use forward slashes on every platform" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("sub/b.bin", try archivePath(arena, "sub\\b.bin"));
    try std.testing.expectEqualStrings("sub/b.bin", try archivePath(arena, "sub/b.bin"));
}

test "folder: archives a tree and verifies the result" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try makeTree(arena, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const out = ".zig-cache/p2z-folder.zar";
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out ++ ".part") catch {};

    var cancelled = std.atomic.Value(bool).init(false);
    const stats = try run(arena, io, root, .{ .output = out, .cancel = &cancelled });
    try std.testing.expectEqual(@as(usize, 3), stats.files);
    try std.testing.expectEqual(@as(usize, 3), stats.dirs);
    try std.testing.expectEqual(@as(u64, 6 + 5 + 70_000), stats.bytes);

    const file = try std.Io.Dir.cwd().openFile(io, out, .{});
    defer file.close(io);
    var reader = try zar.Reader.open(io, file, arena);
    const entries = try reader.entries();
    try std.testing.expectEqual(@as(usize, 6), entries.len);

    const expected = [_][]const u8{ "a.txt", "empty", "sub", "sub/b.bin", "sub/deep", "sub/deep/c.bin" };
    for (expected) |wanted| {
        var found = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, wanted)) found = true;
        }
        try std.testing.expect(found);
    }

    const a = for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, "a.txt")) break entry;
    } else return error.MissingEntry;
    var bytes: [6]u8 = undefined;
    try reader.readFile(a, &bytes);
    try std.testing.expectEqualStrings("alpha\n", &bytes);

    // Refuses to overwrite without the flag.
    try std.testing.expectError(error.OutputExists, run(arena, io, root, .{
        .output = out,
        .cancel = &cancelled,
    }));
}

test "folder: a later root replaces a file of an earlier one" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = ".zig-cache/p2z-merge-base";
    const update = ".zig-cache/p2z-merge-update";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.cwd().deleteTree(io, update) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, update) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/shared");
    try std.Io.Dir.cwd().createDirPath(io, update ++ "/shared");
    try writeFile(io, base ++ "/kept.txt", "only in base\n");
    try writeFile(io, base ++ "/shared/data.bin", "base data\n");
    try writeFile(io, update ++ "/shared/data.bin", "update data\n");
    try writeFile(io, update ++ "/added.txt", "only in update\n");

    const out = ".zig-cache/p2z-merge.zar";
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out ++ ".part") catch {};

    var cancelled = std.atomic.Value(bool).init(false);
    const roots = [_][]const u8{ base, update };
    const stats = try runRoots(arena, io, &roots, .{ .output = out, .cancel = &cancelled });
    try std.testing.expectEqual(@as(usize, 3), stats.files);
    try std.testing.expectEqual(@as(usize, 1), stats.dirs);

    const file = try std.Io.Dir.cwd().openFile(io, out, .{});
    defer file.close(io);
    var reader = try zar.Reader.open(io, file, arena);
    const entries = try reader.entries();
    const data = for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, "shared/data.bin")) break entry;
    } else return error.MissingEntry;
    var bytes: [12]u8 = undefined;
    try reader.readFile(data, bytes[0..@intCast(data.size)]);
    try std.testing.expectEqualStrings("update data\n", bytes[0..@intCast(data.size)]);
}

test "folder: cancel leaves no output and no partial file" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try makeTree(arena, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const out = ".zig-cache/p2z-folder-cancel.zar";
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, run(arena, io, root, .{
        .output = out,
        .cancel = &cancelled,
    }));
    try std.testing.expectEqual(false, fileExists(io, out));
    try std.testing.expectEqual(false, fileExists(io, out ++ ".part"));
}

test "folder: refuses a symlink instead of archiving the link target" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try makeTree(arena, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const link = try std.fmt.allocPrint(arena, "{s}/link.txt", .{root});
    try std.Io.Dir.cwd().symLink(io, "a.txt", link, .{});

    const out = ".zig-cache/p2z-folder-link.zar";
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.UnsupportedEntry, run(arena, io, root, .{
        .output = out,
        .cancel = &cancelled,
    }));
    try std.testing.expectEqual(false, fileExists(io, out));
    try std.testing.expectEqual(false, fileExists(io, out ++ ".part"));
}

test "folder: a missing input is refused before any file is created" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = ".zig-cache/p2z-folder-missing.zar";
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.NotADirectory, run(arena, io, ".zig-cache/p2z-no-such-folder", .{
        .output = out,
        .cancel = &cancelled,
    }));
    try std.testing.expectEqual(false, fileExists(io, out));
}
