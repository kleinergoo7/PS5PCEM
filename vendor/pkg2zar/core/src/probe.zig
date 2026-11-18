// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Reads only what is needed to name an output: header, entry table, and sce_sys/param.sfo.
//! No decryption, so this works even on pkgs the converter would refuse.

const std = @import("std");
const pkg = @import("pkg.zig");
const psf = @import("psf.zig");

pub const Info = struct {
    title: ?[]const u8 = null,
    title_id: ?[]const u8 = null,
    version: ?[]const u8 = null,
    is_patch: bool = false,
    /// Input path, so role messages can name the offending folder.
    path: []const u8 = "",
};

pub const Error = error{
    CannotOpen,
    TooShort,
    BadHeader,
    BadEntryTable,
    MissingParamSfo,
    BadParamSfo,
    OutOfMemory,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.CannotOpen => "cannot open the pkg",
        error.TooShort => "file is shorter than the pkg header",
        error.BadHeader => "pkg header is not readable",
        error.BadEntryTable => "pkg entry table is outside the file",
        error.MissingParamSfo => "pkg has no sce_sys/param.sfo entry",
        error.BadParamSfo => "param.sfo is malformed",
        error.OutOfMemory => "out of memory",
    };
}

pub fn run(io: std.Io, arena: std.mem.Allocator, path: []const u8) Error!Info {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.CannotOpen;
    defer file.close(io);
    const file_size = file.length(io) catch return error.CannotOpen;

    var raw: [pkg.header_size]u8 = undefined;
    const want: usize = @intCast(@min(file_size, raw.len)); // bounded by the buffer
    _ = file.readPositionalAll(io, raw[0..want], 0) catch return error.CannotOpen;
    const header = switch (pkg.parseHeader(raw[0..want], file_size)) {
        .ok => |h| h,
        .fail => |failure| return switch (failure.reason) {
            .too_short => error.TooShort,
            .bad_magic => error.BadHeader,
            .image_out_of_range => error.BadHeader,
        },
    };

    const table_len = @as(u64, header.entry_count) * pkg.entry_size;
    const table_end = std.math.add(u64, header.table_offset, table_len) catch return error.BadEntryTable;
    if (table_end > file_size) return error.BadEntryTable;
    const table = arena.alloc(u8, @intCast(table_len)) catch return error.OutOfMemory;
    _ = file.readPositionalAll(io, table, header.table_offset) catch return error.BadEntryTable;
    const entries = arena.alloc(pkg.Entry, header.entry_count) catch return error.OutOfMemory;
    pkg.parseEntries(table, 0, entries) catch return error.BadEntryTable;

    var info: Info = .{
        .title_id = titleId(&header),
        .is_patch = pkg.isPatch(header.content_flags),
        .path = path,
    };

    var param: ?pkg.Entry = null;
    for (entries) |entry| {
        if (entry.id == pkg.entry_id_param_sfo) {
            param = entry;
            break;
        }
    }
    const sfo_entry = param orelse return info; // header-only info is still useful
    if (@as(u64, sfo_entry.offset) + sfo_entry.size > file_size) return error.BadEntryTable;
    const sfo = arena.alloc(u8, sfo_entry.size) catch return error.OutOfMemory;
    _ = file.readPositionalAll(io, sfo, sfo_entry.offset) catch return error.BadEntryTable;

    info.title = psf.findString(sfo, "TITLE") catch return error.BadParamSfo;
    info.version = psf.findString(sfo, "APP_VER") catch return error.BadParamSfo;
    return info;
}

fn titleId(header: *const pkg.Header) ?[]const u8 {
    return parseTitleId(std.mem.trimEnd(u8, &header.content_id, "\x00 "));
}

/// `CUSAxxxxx` from a content id such as `UP9000-CUSA00191_00-KZ4RELEASE000041`.
fn parseTitleId(content_id: []const u8) ?[]const u8 {
    if (content_id.len < 16 or content_id[6] != '-') return null;
    return content_id[7..16];
}

/// Result of ordering a base folder and an update folder.
pub const RoleCheck = union(enum) {
    ok: struct { base: usize, update: usize },
    missing_title_id: struct { side: usize, path: []const u8 },
    title_mismatch: struct { first: []const u8, second: []const u8 },
    missing_version: struct { side: usize, path: []const u8 },
    same_version: struct { version: []const u8 },
    version_unreadable: struct { side: usize, path: []const u8, version: []const u8 },
};

/// Orders two folder identities. A pkg carries content flags that say which one is the patch;
/// an extracted tree only has APP_VER, so the higher version is the update.
pub fn folderRole(first: Info, second: Info) RoleCheck {
    const a = first.title_id orelse
        return .{ .missing_title_id = .{ .side = 0, .path = first.path } };
    const b = second.title_id orelse
        return .{ .missing_title_id = .{ .side = 1, .path = second.path } };
    if (!std.mem.eql(u8, a, b)) return .{ .title_mismatch = .{ .first = a, .second = b } };

    const va = first.version orelse
        return .{ .missing_version = .{ .side = 0, .path = first.path } };
    const vb = second.version orelse
        return .{ .missing_version = .{ .side = 1, .path = second.path } };

    const order = compareVersions(va, vb) orelse {
        const side: usize = if (std.mem.indexOfNone(u8, va, "0123456789.") != null) 0 else 1;
        return .{ .version_unreadable = .{
            .side = side,
            .path = if (side == 0) first.path else second.path,
            .version = if (side == 0) va else vb,
        } };
    };
    return switch (order) {
        .lt => .{ .ok = .{ .base = 0, .update = 1 } },
        .gt => .{ .ok = .{ .base = 1, .update = 0 } },
        .eq => .{ .same_version = .{ .version = va } },
    };
}

/// Dotted numeric compare; null when a component is not a number. Missing components are 0,
/// so `1.0` equals `1.0.0`.
fn compareVersions(a: []const u8, b: []const u8) ?std.math.Order {
    var parts_a = std.mem.splitScalar(u8, a, '.');
    var parts_b = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const ca = parts_a.next();
        const cb = parts_b.next();
        if (ca == null and cb == null) return .eq;
        const va = if (ca) |text| parseVersionPart(text) orelse return null else 0;
        const vb = if (cb) |text| parseVersionPart(text) orelse return null else 0;
        if (va < vb) return .lt;
        if (va > vb) return .gt;
    }
}

fn parseVersionPart(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// Identity of an already extracted folder: `<root>/sce_sys/param.sfo`. A folder without one
/// is not an error; the caller falls back to the folder name.
pub fn runFolder(io: std.Io, arena: std.mem.Allocator, root: []const u8) Error!Info {
    const path = std.fmt.allocPrint(arena, "{s}/sce_sys/param.sfo", .{root}) catch
        return error.OutOfMemory;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .{};
    defer file.close(io);

    const size = file.length(io) catch return .{};
    // The real file is about 1 KiB; a bigger one is not a param.sfo.
    if (size > 1024 * 1024) return error.BadParamSfo;
    const bytes = arena.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    const read = file.readPositionalAll(io, bytes, 0) catch return error.BadParamSfo;
    if (read != bytes.len) return error.BadParamSfo;

    var info: Info = .{ .path = root };
    info.title = psf.findString(bytes, "TITLE") catch return error.BadParamSfo;
    info.version = psf.findString(bytes, "APP_VER") catch return error.BadParamSfo;
    if (info.version == null) {
        info.version = psf.findString(bytes, "VERSION") catch return error.BadParamSfo;
    }
    const declared_id = psf.findString(bytes, "TITLE_ID") catch return error.BadParamSfo;
    const content_id = psf.findString(bytes, "CONTENT_ID") catch return error.BadParamSfo;
    info.title_id = declared_id orelse if (content_id) |id| parseTitleId(id) else null;
    return info;
}

test "folderRole: the higher APP_VER is the update" {
    const base: Info = .{ .title_id = "CUSA00191", .version = "01.00", .path = "base/" };
    const update: Info = .{ .title_id = "CUSA00191", .version = "01.81", .path = "update/" };

    switch (folderRole(base, update)) {
        .ok => |pair| {
            try std.testing.expectEqual(@as(usize, 0), pair.base);
            try std.testing.expectEqual(@as(usize, 1), pair.update);
        },
        else => return error.UnexpectedRole,
    }
    // The same pair in the other order must flip the indices, not the answer.
    switch (folderRole(update, base)) {
        .ok => |pair| {
            try std.testing.expectEqual(@as(usize, 1), pair.base);
            try std.testing.expectEqual(@as(usize, 0), pair.update);
        },
        else => return error.UnexpectedRole,
    }
}

test "folderRole: refuses equal versions and mismatched title ids" {
    const a: Info = .{ .title_id = "CUSA00191", .version = "01.81", .path = "a/" };
    const same: Info = .{ .title_id = "CUSA00191", .version = "01.81", .path = "b/" };
    switch (folderRole(a, same)) {
        .same_version => |f| try std.testing.expectEqualStrings("01.81", f.version),
        else => return error.UnexpectedRole,
    }

    const other: Info = .{ .title_id = "CUSA00190", .version = "01.00", .path = "c/" };
    switch (folderRole(a, other)) {
        .title_mismatch => |f| {
            try std.testing.expectEqualStrings("CUSA00191", f.first);
            try std.testing.expectEqualStrings("CUSA00190", f.second);
        },
        else => return error.UnexpectedRole,
    }

    const unreadable: Info = .{ .title_id = "CUSA00191", .version = "01.x", .path = "d/" };
    switch (folderRole(a, unreadable)) {
        .version_unreadable => |f| try std.testing.expectEqualStrings("01.x", f.version),
        else => return error.UnexpectedRole,
    }
}

test "probe: a folder identity comes from sce_sys/param.sfo" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const test_pkg = @import("test_pkg.zig");

    const root = ".zig-cache/p2z-probe-folder";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sce_sys");

    const sfo = try test_pkg.paramSfo(arena, .{ .title = "Synthetic Game", .app_ver = "01.02" });
    const file = try std.Io.Dir.cwd().createFile(io, root ++ "/sce_sys/param.sfo", .{ .truncate = true });
    try file.writeStreamingAll(io, sfo);
    file.close(io);

    const info = try runFolder(io, arena, root);
    try std.testing.expectEqualStrings("Synthetic Game", info.title.?);
    try std.testing.expectEqualStrings("01.02", info.version.?);
    try std.testing.expectEqual(@as(?[]const u8, null), info.title_id);
    try std.testing.expect(!info.is_patch);

    // A folder without the file keeps working: empty identity, no error.
    try std.Io.Dir.cwd().createDirPath(io, root ++ "-bare");
    defer std.Io.Dir.cwd().deleteTree(io, root ++ "-bare") catch {};
    const bare = try runFolder(io, arena, root ++ "-bare");
    try std.testing.expectEqual(@as(?[]const u8, null), bare.title);
    try std.testing.expectEqual(@as(?[]const u8, null), bare.version);
}

test "integration: probe reads the real title, id and version" {
    const path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const info = try run(std.testing.io, arena_state.allocator(), path);
    try std.testing.expectEqualStrings("Terraria", info.title.?);
    try std.testing.expectEqualStrings("CUSA00740", info.title_id.?);
    try std.testing.expect(info.version != null);
    try std.testing.expect(!info.is_patch);
    std.debug.print("probe: title={s} id={s} version={s}\n", .{ info.title.?, info.title_id.?, info.version.? });
}
