// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! param.sfo reader for PS4-mode title detection.
//!
//! Both PS4 and PS5 titles ship `sce_sys/param.sfo` in PSF format. PS4 mode
//! only needs a handful of keys (TITLE_ID, CATEGORY, APP_VER, FW VERSION), so
//! this is a read-only, allocation-free parser over the caller's buffer rather
//! than a general PSF editor.

const std = @import("std");

pub const Error = error{
    Truncated,
    BadMagic,
    BadVersion,
    BadOffset,
};

pub const magic = [4]u8{ 0x00, 'P', 'S', 'F' };

pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    key_table_start: u32,
    data_table_start: u32,
    entry_count: u32,
};

pub const IndexEntry = extern struct {
    key_offset: u16,
    data_fmt: u16,
    data_len: u32,
    data_max_len: u32,
    data_offset: u32,
};

pub const FmtUtf8: u16 = 0x0204;
pub const FmtInt32: u16 = 0x0404;

comptime {
    std.debug.assert(@sizeOf(Header) == 20);
    std.debug.assert(@sizeOf(IndexEntry) == 16);
}

/// Borrowed view of one entry.
pub const Entry = struct {
    key: []const u8,
    fmt: u16,
    data: []const u8,
};

fn readAt(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const end = std.math.add(usize, offset, @sizeOf(T)) catch return Error.Truncated;
    if (end > bytes.len) return Error.Truncated;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[offset..end]);
    return value;
}

fn cStr(bytes: []const u8, offset: usize, limit: usize) Error![]const u8 {
    if (offset > limit or offset > bytes.len) return Error.BadOffset;
    const end_cap = @min(limit, bytes.len);
    var end = offset;
    while (end < end_cap and bytes[end] != 0) : (end += 1) {}
    return bytes[offset..end];
}

/// Number of entries, or error when the header itself is invalid.
pub fn entryCount(bytes: []const u8) Error!u32 {
    const header = try readAt(Header, bytes, 0);
    if (!std.mem.eql(u8, &header.magic, &magic)) return Error.BadMagic;
    if (header.version != 0x101) return Error.BadVersion;
    return header.entry_count;
}

/// Fetch entry `index` as borrowed slices.
pub fn entryAt(bytes: []const u8, index: usize) Error!?Entry {
    const header = try readAt(Header, bytes, 0);
    if (!std.mem.eql(u8, &header.magic, &magic)) return Error.BadMagic;
    if (header.version != 0x101) return Error.BadVersion;
    if (index >= header.entry_count) return null;
    const ie = try readAt(IndexEntry, bytes, @sizeOf(Header) + index * @sizeOf(IndexEntry));
    const key = try cStr(bytes, header.key_table_start + ie.key_offset, header.data_table_start);
    const data_off = std.math.add(usize, header.data_table_start, ie.data_offset) catch return Error.BadOffset;
    const data_end = std.math.add(usize, data_off, ie.data_len) catch return Error.BadOffset;
    if (data_end > bytes.len) return Error.Truncated;
    return .{ .key = key, .fmt = ie.data_fmt, .data = bytes[data_off..data_end] };
}

/// Find an entry by key name. Linear scan is fine: param.sfo has ~20 keys.
pub fn find(bytes: []const u8, key: []const u8) Error!?Entry {
    const n = try entryCount(bytes);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = (try entryAt(bytes, i)) orelse return null;
        if (std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

/// Read a UTF-8 string value (NUL-terminated in the file, returned trimmed).
pub fn getString(bytes: []const u8, key: []const u8) Error!?[]const u8 {
    const e = (try find(bytes, key)) orelse return null;
    if (e.fmt != FmtUtf8) return Error.BadOffset;
    return std.mem.sliceTo(e.data, 0);
}

/// Read a 32-bit integer value.
pub fn getU32(bytes: []const u8, key: []const u8) Error!?u32 {
    const e = (try find(bytes, key)) orelse return null;
    if (e.fmt != FmtInt32 or e.data.len < 4) return Error.BadOffset;
    return std.mem.readInt(u32, e.data[0..4], .little);
}

// --- test helper: build a minimal two-key SFO in the caller's buffer ---

fn writeTestSfo(buf: []u8) []const u8 {
    // Keys: "TITLE_ID" (utf8 "CUSA00001"), "CATEGORY" (utf8 "gd").
    // Written with explicit offsets so the helper builds on Zig 0.16 and 0.17.
    const keys = "TITLE_ID\x00CATEGORY\x00";
    const hdr_len = @sizeOf(Header) + 2 * @sizeOf(IndexEntry);
    const key_off: u32 = @intCast(hdr_len);
    const data_off: u32 = @intCast(hdr_len + keys.len);
    var pos: usize = 0;
    const total = data_off + 20;
    std.debug.assert(buf.len >= total);
    @memcpy(buf[pos..][0..4], &magic);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0x101, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], key_off, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], data_off, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 2, .little);
    pos += 4;
    // entry 0: TITLE_ID at key 0, data at 0, len 10
    std.mem.writeInt(u16, buf[pos..][0..2], 0, .little);
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], FmtUtf8, .little);
    pos += 2;
    std.mem.writeInt(u32, buf[pos..][0..4], 10, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 16, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .little);
    pos += 4;
    // entry 1: CATEGORY at key 9, data at 16, len 3
    std.mem.writeInt(u16, buf[pos..][0..2], 9, .little);
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], FmtUtf8, .little);
    pos += 2;
    std.mem.writeInt(u32, buf[pos..][0..4], 3, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 4, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 16, .little);
    pos += 4;
    @memcpy(buf[pos..][0..keys.len], keys);
    pos += keys.len;
    @memcpy(buf[pos..][0..10], "CUSA00001\x00");
    pos += 10;
    // pad data[10..16] with zeroes so CATEGORY lands at data offset 16
    @memset(buf[pos..][0..6], 0);
    pos += 6;
    @memcpy(buf[pos..][0..4], "gd\x00\x00");
    pos += 4;
    return buf[0..pos];
}

test "sfo parses synthetic param.sfo" {
    var buf: [256]u8 = undefined;
    const bytes = writeTestSfo(&buf);
    try std.testing.expectEqual(@as(u32, 2), try entryCount(bytes));
    const title = (try getString(bytes, "TITLE_ID")) orelse return error.MissingTitle;
    try std.testing.expectEqualStrings("CUSA00001", title);
    const cat = (try getString(bytes, "CATEGORY")) orelse return error.MissingCategory;
    try std.testing.expectEqualStrings("gd", cat);
    try std.testing.expect((try find(bytes, "NOPE")) == null);
}

test "sfo rejects bad magic" {
    var buf: [32]u8 = undefined;
    @memset(&buf, 0);
    try std.testing.expectError(Error.BadMagic, entryCount(&buf));
}
