// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Minimal PSF reader: enough of `sce_sys/param.sfo` to get TITLE and APP_VER.
//! Layout: "\0PSF" magic, u32 offsets and count, 16-byte index rows, key table, data table.

const std = @import("std");

pub const magic = [4]u8{ 0x00, 'P', 'S', 'F' };
pub const format_utf8: u16 = 0x0404;

pub const Error = error{
    TooShort,
    BadMagic,
    BadTables,
    KeyNotFound,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.TooShort => "param.sfo is shorter than its header",
        error.BadMagic => "param.sfo does not start with \\0PSF",
        error.BadTables => "param.sfo index or tables point outside the file",
        error.KeyNotFound => "param.sfo has no such key",
    };
}

pub const Header = struct {
    count: u32,
    key_table: u32,
    data_table: u32,
    index_offset: usize,
};

pub fn parseHeader(bytes: []const u8) Error!Header {
    if (bytes.len < 0x14) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.BadMagic;
    const key_table = readU32(bytes, 8);
    const data_table = readU32(bytes, 12);
    const count = readU32(bytes, 16);
    if (key_table > bytes.len or data_table > bytes.len) return error.BadTables;
    const index_end = 0x14 + @as(usize, count) * 16;
    if (index_end > bytes.len) return error.BadTables;
    return .{ .count = count, .key_table = key_table, .data_table = data_table, .index_offset = 0x14 };
}

/// Returns the raw value bytes for `key`, or null when the key is absent.
pub fn find(bytes: []const u8, key: []const u8) Error!?[]const u8 {
    const header = try parseHeader(bytes);
    for (0..header.count) |i| {
        const row = header.index_offset + i * 16;
        const key_offset: usize = readU16(bytes, row);
        const format = readU16(bytes, row + 2);
        const len: usize = readU32(bytes, row + 4);
        const data_offset: usize = readU32(bytes, row + 12);

        const key_start = @as(usize, header.key_table) + key_offset;
        if (key_start >= bytes.len) return error.BadTables;
        const rest = bytes[key_start..];
        const key_end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.BadTables;
        if (!std.mem.eql(u8, rest[0..key_end], key)) continue;
        _ = format; // string fields in the wild use 0x0004, 0x0204 and 0x0404

        const value_start = @as(usize, header.data_table) + data_offset;
        if (value_start + len > bytes.len) return error.BadTables;
        return bytes[value_start .. value_start + len];
    }
    return null;
}

/// Convenience for string fields: trims trailing NULs.
pub fn findString(bytes: []const u8, key: []const u8) Error!?[]const u8 {
    const value = (try find(bytes, key)) orelse return null;
    return std.mem.trimEnd(u8, value, "\x00");
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn testSfo(arena: std.mem.Allocator) ![]u8 {
    // Two string entries: TITLE and APP_VER.
    const keys = "TITLE\x00APP_VER\x00";
    const values = "Terraria\x00" ++ "01.00\x00";
    const count = 2;
    const key_table = 0x14 + count * 16;
    const data_table = key_table + keys.len;
    var out = try arena.alloc(u8, data_table + values.len);
    @memset(out, 0);
    @memcpy(out[0..4], &magic);
    std.mem.writeInt(u32, out[8..12], key_table, .little);
    std.mem.writeInt(u32, out[12..16], data_table, .little);
    std.mem.writeInt(u32, out[16..20], count, .little);
    std.mem.writeInt(u16, out[0x14..0x16], 0, .little);
    std.mem.writeInt(u16, out[0x16..0x18], format_utf8, .little);
    std.mem.writeInt(u32, out[0x18..0x1c], 9, .little);
    std.mem.writeInt(u32, out[0x20..0x24], 0, .little);
    std.mem.writeInt(u16, out[0x24..0x26], 6, .little);
    std.mem.writeInt(u16, out[0x26..0x28], format_utf8, .little);
    std.mem.writeInt(u32, out[0x28..0x2c], 6, .little);
    std.mem.writeInt(u32, out[0x30..0x34], 9, .little);
    @memcpy(out[key_table..][0..keys.len], keys);
    @memcpy(out[data_table..][0..values.len], values);
    return out;
}

test "psf: reads TITLE and APP_VER" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const bytes = try testSfo(arena_state.allocator());

    try std.testing.expectEqualStrings("Terraria", (try findString(bytes, "TITLE")).?);
    try std.testing.expectEqualStrings("01.00", (try findString(bytes, "APP_VER")).?);
    try std.testing.expect((try findString(bytes, "NOPE")) == null);
}

test "psf: refuses a wrong magic" {
    var bytes: [0x40]u8 = @splat(0);
    try std.testing.expectError(error.BadMagic, findString(&bytes, "TITLE"));
}
