// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Piece sets: a pkg split into `<prefix>_<N>.pkg` slices of one byte stream. Piece 0 holds
//! the header. The user's explicit selection is the contract; the filename pattern is only
//! used to order and validate the set.

const std = @import("std");

pub const Piece = struct {
    path: []const u8,
    number: u32,
    size: u64,
};

pub const Failure = union(enum) {
    bad_name: []const u8,
    duplicate: u32,
    missing_zero,
    gap: u32,
    mixed_prefix: []const u8,
    size_mismatch: struct { declared: u64, actual: u64 },
};

pub const Result = union(enum) {
    ok: []Piece,
    fail: Failure,
};

pub fn describe(failure: Failure, buf: []u8) []const u8 {
    return switch (failure) {
        .bad_name => |path| std.fmt.bufPrint(buf, "{s}: name does not end in _<number>.pkg", .{path}) catch "bad piece name",
        .duplicate => |n| std.fmt.bufPrint(buf, "piece {d} appears more than once", .{n}) catch "duplicate piece",
        .missing_zero => "piece 0 is missing, the header lives there",
        .gap => |n| std.fmt.bufPrint(buf, "piece {d} is missing", .{n}) catch "gap in piece set",
        .mixed_prefix => |path| std.fmt.bufPrint(buf, "{s}: piece prefix differs from the rest of the set", .{path}) catch "mixed piece prefixes",
        .size_mismatch => |m| std.fmt.bufPrint(buf, "piece sizes sum to {d}, header declares {d}", .{ m.actual, m.declared }) catch "piece size mismatch",
    };
}

/// Parses `name_N.pkg` (case-insensitive suffix) into N. Returns null when the name does not
/// follow the pattern.
pub fn parseNumber(filename: []const u8) ?u32 {
    const base = filename;
    if (base.len < 7) return null;
    var end = base.len;
    if (std.ascii.endsWithIgnoreCase(base, ".pkg")) end -= 4;
    if (end == 0 or base[end - 1] < '0' or base[end - 1] > '9') return null;

    var digits_start = end;
    while (digits_start > 0 and base[digits_start - 1] >= '0' and base[digits_start - 1] <= '9') {
        digits_start -= 1;
    }
    if (digits_start < 2 or base[digits_start - 1] != '_') return null;
    return std.fmt.parseInt(u32, base[digits_start..end], 10) catch null;
}

pub const Input = struct {
    path: []const u8,
    size: u64,
};

/// True when every path parses as `prefix_N.pkg` with the same prefix and the numbers are
/// distinct. Used to tell a piece set from two unrelated pkgs before opening anything.
pub fn looksLikeSet(paths: []const []const u8) bool {
    if (paths.len < 2) return false;
    var prefix: ?[]const u8 = null;
    for (paths, 0..) |path, i| {
        _ = parseNumber(path) orelse return false;
        const cut = std.mem.lastIndexOfScalar(u8, path, '_') orelse return false;
        const this_prefix = path[0..cut];
        if (prefix) |p| {
            if (!std.mem.eql(u8, p, this_prefix)) return false;
        } else prefix = this_prefix;
        for (paths[0..i]) |earlier| {
            if (parseNumber(earlier) == parseNumber(path)) return false;
        }
    }
    return true;
}

/// Orders and validates a selected set. Single-file selections are returned as-is without
/// requiring the naming pattern.
pub fn order(arena: std.mem.Allocator, inputs: []const Input) !Result {
    if (inputs.len == 1) {
        const pieces = try arena.alloc(Piece, 1);
        pieces[0] = .{ .path = inputs[0].path, .number = parseNumber(inputs[0].path) orelse 0, .size = inputs[0].size };
        return .{ .ok = pieces };
    }

    const pieces = try arena.alloc(Piece, inputs.len);
    var prefix: ?[]const u8 = null;
    for (inputs, 0..) |input, i| {
        const number = parseNumber(input.path) orelse return .{ .fail = .{ .bad_name = input.path } };
        pieces[i] = .{ .path = input.path, .number = number, .size = input.size };

        const cut = std.mem.lastIndexOfScalar(u8, input.path, '_') orelse return .{ .fail = .{ .bad_name = input.path } };
        const this_prefix = input.path[0..cut];
        if (prefix) |p| {
            if (!std.mem.eql(u8, p, this_prefix)) return .{ .fail = .{ .mixed_prefix = input.path } };
        } else prefix = this_prefix;
    }

    std.mem.sort(Piece, pieces, {}, struct {
        fn lessThan(_: void, a: Piece, b: Piece) bool {
            return a.number < b.number;
        }
    }.lessThan);

    for (pieces, 0..) |piece, i| {
        if (i > 0 and piece.number == pieces[i - 1].number) return .{ .fail = .{ .duplicate = piece.number } };
    }
    for (pieces, 0..) |piece, i| {
        const expected: u32 = @intCast(i);
        if (piece.number != expected) {
            if (expected == 0) return .{ .fail = .missing_zero };
            return .{ .fail = .{ .gap = expected } };
        }
    }
    return .{ .ok = pieces };
}

/// Checks the piece sizes against the package size declared in piece 0's header.
pub fn validateSizes(pieces: []const Piece, declared: u64) ?Failure {
    var total: u64 = 0;
    for (pieces) |piece| {
        total = std.math.add(u64, total, piece.size) catch
            return .{ .size_mismatch = .{ .declared = declared, .actual = std.math.maxInt(u64) } };
    }
    if (total != declared) return .{ .size_mismatch = .{ .declared = declared, .actual = total } };
    return null;
}

/// Virtual byte range over an ordered piece set. Offsets are absolute across all pieces.
pub const Stream = struct {
    io: std.Io,
    files: []const std.Io.File,
    sizes: []const u64,
    total: u64,

    pub fn init(io: std.Io, files: []const std.Io.File, sizes: []const u64) Stream {
        var total: u64 = 0;
        for (sizes) |size| total += size;
        return .{ .io = io, .files = files, .sizes = sizes, .total = total };
    }

    /// Reads up to `buf.len` bytes at `offset`. Returns 0 at end of stream.
    pub fn readAt(self: Stream, io: std.Io, offset: u64, buf: []u8) !usize {
        if (offset >= self.total) return 0;
        var remaining = buf.len;
        var written: usize = 0;
        var absolute = offset;
        for (self.files, self.sizes) |file, size| {
            if (remaining == 0) break;
            if (absolute >= size) {
                absolute -= size;
                continue;
            }
            const want = @min(remaining, size - absolute);
            const n = try file.readPositionalAll(io, buf[written..][0..want], absolute);
            if (n != want) return error.UnexpectedEndOfFile;
            written += n;
            remaining -= n;
            absolute = 0;
        }
        return written;
    }

    /// Fills `buf` completely or fails.
    pub fn readExact(self: Stream, io: std.Io, offset: u64, buf: []u8) !void {
        const n = try self.readAt(io, offset, buf);
        if (n != buf.len) return error.UnexpectedEndOfFile;
    }
};

test "parseNumber: accepts the scene naming pattern" {
    try std.testing.expectEqual(@as(?u32, 0), parseNumber("UP0001-CUSA12345_00-GAME000000000000_0.pkg"));
    try std.testing.expectEqual(@as(?u32, 12), parseNumber("CUSA00740_12.pkg"));
    try std.testing.expectEqual(@as(?u32, 12), parseNumber("CUSA00740_12.PKG"));
    try std.testing.expectEqual(@as(?u32, null), parseNumber("CUSA00740.pkg"));
    try std.testing.expectEqual(@as(?u32, null), parseNumber("CUSA00740_a.pkg"));
    try std.testing.expectEqual(@as(?u32, null), parseNumber("_12.pkg"));
}

test "looksLikeSet: separates piece sets from unrelated pkgs" {
    const set = [_][]const u8{ "GAME_2.pkg", "GAME_0.pkg", "GAME_1.pkg" };
    try std.testing.expect(looksLikeSet(&set));
    const unrelated = [_][]const u8{ "base.pkg", "update.pkg" };
    try std.testing.expect(!looksLikeSet(&unrelated));
    const dupes = [_][]const u8{ "GAME_0.pkg", "GAME_0.pkg" };
    try std.testing.expect(!looksLikeSet(&dupes));
    const one = [_][]const u8{"GAME_0.pkg"};
    try std.testing.expect(!looksLikeSet(&one));
}

test "order: accepts a contiguous three-piece set in any input order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inputs = [_]Input{
        .{ .path = "GAME_2.pkg", .size = 300 },
        .{ .path = "GAME_0.pkg", .size = 100 },
        .{ .path = "GAME_1.pkg", .size = 200 },
    };
    const result = try order(arena, &inputs);
    const pieces = switch (result) {
        .ok => |p| p,
        .fail => return error.UnexpectedFailure,
    };
    try std.testing.expectEqual(@as(usize, 3), pieces.len);
    try std.testing.expectEqual(@as(u32, 0), pieces[0].number);
    try std.testing.expectEqual(@as(u64, 100), pieces[0].size);
    try std.testing.expectEqual(@as(u32, 2), pieces[2].number);
}

test "order: refuses a duplicate piece number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inputs = [_]Input{
        .{ .path = "GAME_0.pkg", .size = 100 },
        .{ .path = "GAME_1.pkg", .size = 100 },
        .{ .path = "GAME_1.pkg", .size = 100 },
    };
    const result = try order(arena, &inputs);
    switch (result) {
        .ok => return error.ExpectedFailure,
        .fail => |f| switch (f) {
            .duplicate => |n| try std.testing.expectEqual(@as(u32, 1), n),
            else => return error.WrongFailure,
        },
    }
}

test "order: refuses a gap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inputs = [_]Input{
        .{ .path = "GAME_0.pkg", .size = 100 },
        .{ .path = "GAME_2.pkg", .size = 100 },
    };
    switch (try order(arena, &inputs)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| switch (f) {
            .gap => |n| try std.testing.expectEqual(@as(u32, 1), n),
            else => return error.WrongFailure,
        },
    }
}

test "order: refuses a set without piece 0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inputs = [_]Input{
        .{ .path = "GAME_1.pkg", .size = 100 },
        .{ .path = "GAME_2.pkg", .size = 100 },
    };
    switch (try order(arena, &inputs)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| try std.testing.expect(f == .missing_zero),
    }
}

test "order: refuses mixed prefixes and unparseable names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mixed = [_]Input{
        .{ .path = "GAME_0.pkg", .size = 100 },
        .{ .path = "OTHER_1.pkg", .size = 100 },
    };
    switch (try order(arena, &mixed)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| try std.testing.expect(f == .mixed_prefix),
    }

    const bad = [_]Input{
        .{ .path = "GAME_0.pkg", .size = 100 },
        .{ .path = "GAME.pkg", .size = 100 },
    };
    switch (try order(arena, &bad)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| try std.testing.expect(f == .bad_name),
    }
}

test "validateSizes: catches a size sum mismatch" {
    const pieces = [_]Piece{
        .{ .path = "a", .number = 0, .size = 100 },
        .{ .path = "b", .number = 1, .size = 100 },
    };
    try std.testing.expect(validateSizes(&pieces, 200) == null);
    switch (validateSizes(&pieces, 201) orelse return error.ExpectedFailure) {
        .size_mismatch => |m| {
            try std.testing.expectEqual(@as(u64, 201), m.declared);
            try std.testing.expectEqual(@as(u64, 200), m.actual);
        },
        else => return error.WrongFailure,
    }
}

test "stream: reads across piece boundaries" {
    const io = std.testing.io;
    const names = [_][]const u8{ "p2z-piece-0.bin", "p2z-piece-1.bin" };
    defer for (names) |name| std.Io.Dir.cwd().deleteFile(io, name) catch {};

    const text0 = "abcde";
    const text1 = "FGHIJ";
    const sizes = [_]u64{ text0.len, text1.len };

    var files: [2]std.Io.File = undefined;
    for (names, 0..) |name, i| {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .read = true, .truncate = true });
        files[i] = f;
        try f.writeStreamingAll(io, if (i == 0) text0 else text1);
    }
    defer for (files) |f| f.close(io);

    const stream = Stream.init(io, &files, &sizes);
    var buf: [4]u8 = undefined;
    try stream.readExact(io, 3, &buf);
    try std.testing.expectEqualStrings("deFG", &buf);
    try stream.readExact(io, 8, buf[0..2]);
    try std.testing.expectEqualStrings("IJ", buf[0..2]);
    try std.testing.expectEqual(@as(usize, 0), try stream.readAt(io, 10, &buf));
}

test "integration: real header survives a three-piece split" {
    const path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;

    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer source.close(io);

    var header: [0x1000]u8 = undefined;
    _ = try source.readPositionalAll(io, &header, 0);

    const names = [_][]const u8{ ".zig-cache/p2z-int_0.pkg", ".zig-cache/p2z-int_1.pkg", ".zig-cache/p2z-int_2.pkg" };
    defer for (names) |name| std.Io.Dir.cwd().deleteFile(io, name) catch {};

    const chunks = [_]usize{ 0x600, 0x500, 0x500 };
    var files: [3]std.Io.File = undefined;
    var sizes: [3]u64 = undefined;
    var inputs: [3]Input = undefined;
    var cursor: usize = 0;
    for (names, 0..) |name, i| {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .read = true, .truncate = true });
        files[i] = f;
        try f.writeStreamingAll(io, header[cursor..][0..chunks[i]]);
        cursor += chunks[i];
        sizes[i] = chunks[i];
        inputs[i] = .{ .path = name, .size = chunks[i] };
    }
    defer for (files) |f| f.close(io);

    const pieces = switch (try order(arena, &inputs)) {
        .ok => |p| p,
        .fail => return error.UnexpectedFailure,
    };
    try std.testing.expectEqual(@as(usize, 3), pieces.len);
    try std.testing.expect(validateSizes(pieces, 0x1000) == null);

    const stream = Stream.init(io, &files, &sizes);
    var rebuilt: [0x1000]u8 = undefined;
    try stream.readExact(io, 0, &rebuilt);
    try std.testing.expectEqualSlices(u8, &header, &rebuilt);
}
