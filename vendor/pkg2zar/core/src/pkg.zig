// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! PS4 pkg header: offsets and decoding only. Entry table and PFS image come later.
//! Field offsets were confirmed against the two fixtures in test-rom/ (handoff §6).

const std = @import("std");
const pkg_names = @import("pkg_names.zig");

pub const header_size: usize = 0x1000;
pub const magic = [4]u8{ 0x7f, 'C', 'N', 'T' };

pub const content_id_offset: usize = 0x40;
pub const content_id_len: usize = 0x24;
pub const file_count_offset: usize = 0x0C;
pub const entry_count_offset: usize = 0x10;
pub const table_offset_offset: usize = 0x18;
pub const body_offset_offset: usize = 0x20;
pub const body_size_offset: usize = 0x28;
pub const pfs_image_count_offset: usize = 0x400;
pub const pfs_image_offset_offset: usize = 0x410;
pub const pfs_image_size_offset: usize = 0x418;
pub const mount_image_size_offset: usize = 0x428;
pub const package_size_offset: usize = 0x430;
pub const pfs_signed_size_offset: usize = 0x438;
pub const pfs_cache_size_offset: usize = 0x43C;
pub const split_size_0_offset: usize = 0x480;
pub const split_size_1_offset: usize = 0x488;
pub const content_type_offset: usize = 0x74;
pub const content_flags_offset: usize = 0x78;

/// pkg entry ids that carry key material rather than files.
pub const entry_id_digests: u32 = 0x1;
pub const entry_id_entry_keys: u32 = 0x10;
pub const entry_id_image_key: u32 = 0x20;
pub const entry_id_entry_names: u32 = 0x200;
pub const entry_id_param_sfo: u32 = 0x1000;

/// Entry id to `sce_sys` name, from the shadPS4Plus table. Entries outside it are written as
/// their decimal id by the extractor.
pub fn entryNameById(id: u32) ?[]const u8 {
    return pkg_names.name(id);
}

pub const content_flag_delta_patch: u32 = 0x41000000;
pub const content_flag_first_patch: u32 = 0x100000;
pub const content_flag_subsequent_patch: u32 = 0x40000000;
pub const content_flag_cumulative_patch: u32 = 0x60000000;

pub const Header = struct {
    content_id: [content_id_len]u8,
    file_count: u32,
    entry_count: u32,
    table_offset: u32,
    body_offset: u64,
    body_size: u64,
    pfs_image_count: u32,
    pfs_image_offset: u64,
    pfs_image_size: u64,
    mount_image_size: u64,
    package_size: u64,
    split_sizes: [2]u64,
    pfs_signed_size: u32,
    pfs_cache_size: u32,
    content_type: u32,
    content_flags: u32,
};

pub const Entry = struct {
    id: u32,
    filename_offset: u32,
    flags1: u32,
    flags2: u32,
    offset: u32,
    size: u32,
};

pub const entry_size: usize = 32;

pub const Reason = enum {
    too_short,
    bad_magic,
    image_out_of_range,
};

pub const Failure = struct {
    reason: Reason,
    offset: usize,
};

pub const Result = union(enum) {
    ok: Header,
    fail: Failure,
};

pub fn reasonName(reason: Reason) []const u8 {
    return switch (reason) {
        .too_short => "file shorter than the 0x1000 byte header",
        .bad_magic => "not a pkg: expected magic 7F 43 4E 54",
        .image_out_of_range => "pfs image extends past the end of the file, likely truncated",
    };
}

/// `bytes` may be shorter than the file, but must contain the whole header.
/// `file_size` is the real size, used for the truncation check.
pub fn parseHeader(bytes: []const u8, file_size: u64) Result {
    if (bytes.len < header_size) {
        return .{ .fail = .{ .reason = .too_short, .offset = bytes.len } };
    }
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) {
        return .{ .fail = .{ .reason = .bad_magic, .offset = 0 } };
    }

    const header: Header = .{
        .content_id = bytes[content_id_offset..][0..content_id_len].*,
        .file_count = readU32(bytes, file_count_offset),
        .entry_count = readU32(bytes, entry_count_offset),
        .table_offset = readU32(bytes, table_offset_offset),
        .body_offset = readU64(bytes, body_offset_offset),
        .body_size = readU64(bytes, body_size_offset),
        .pfs_image_count = readU32(bytes, pfs_image_count_offset),
        .pfs_image_offset = readU64(bytes, pfs_image_offset_offset),
        .pfs_image_size = readU64(bytes, pfs_image_size_offset),
        .mount_image_size = readU64(bytes, mount_image_size_offset),
        .package_size = readU64(bytes, package_size_offset),
        .split_sizes = .{
            readU64(bytes, split_size_0_offset),
            readU64(bytes, split_size_1_offset),
        },
        .pfs_signed_size = readU32(bytes, pfs_signed_size_offset),
        .pfs_cache_size = readU32(bytes, pfs_cache_size_offset),
        .content_type = readU32(bytes, content_type_offset),
        .content_flags = readU32(bytes, content_flags_offset),
    };

    // Overflow means the values are nonsense, not a huge pkg.
    const image_end = std.math.add(u64, header.pfs_image_offset, header.pfs_image_size) catch {
        return .{ .fail = .{ .reason = .image_out_of_range, .offset = pfs_image_size_offset } };
    };
    if (image_end > file_size) {
        return .{ .fail = .{ .reason = .image_out_of_range, .offset = pfs_image_size_offset } };
    }

    return .{ .ok = header };
}

pub const EntryTableError = error{BadOffset};

/// Parse the entry table. `entries.len` must equal the header's entry count.
pub fn parseEntries(bytes: []const u8, table_offset: u64, entries: []Entry) EntryTableError!void {
    const start: usize = std.math.cast(usize, table_offset) orelse return error.BadOffset;
    const need = std.math.mul(usize, entries.len, entry_size) catch return error.BadOffset;
    if (start > bytes.len or bytes.len - start < need) return error.BadOffset;
    for (entries, 0..) |*entry, i| {
        const off = start + i * entry_size;
        entry.* = .{
            .id = readU32(bytes, off),
            .filename_offset = readU32(bytes, off + 4),
            .flags1 = readU32(bytes, off + 8),
            .flags2 = readU32(bytes, off + 12),
            .offset = readU32(bytes, off + 16),
            .size = readU32(bytes, off + 20),
        };
    }
}

/// The sce_sys NP entries are stored encrypted with a key derived from their own row.
pub fn entryNeedsDecryption(id: u32) bool {
    return id == 0x400 or id == 0x401 or id == 0x402 or id == 0x403;
}

pub fn isPatch(flags: u32) bool {
    return flags & content_flag_subsequent_patch != 0 or flags & content_flag_first_patch != 0;
}

pub fn isDeltaPatch(flags: u32) bool {
    return flags & content_flag_delta_patch == content_flag_delta_patch;
}

/// Use only after parseHeader returned .ok; the header bounds are already checked.
fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .big);
}

fn testHeader(alloc_bytes: *[header_size]u8) []u8 {
    @memset(alloc_bytes, 0);
    @memcpy(alloc_bytes[0..magic.len], &magic);
    @memcpy(alloc_bytes[content_id_offset..][0..content_id_len], "UP4040-CUSA00740_00-TERRARIA00000001");
    std.mem.writeInt(u32, alloc_bytes[file_count_offset..][0..4], 15, .big);
    std.mem.writeInt(u32, alloc_bytes[entry_count_offset..][0..4], 32, .big);
    std.mem.writeInt(u32, alloc_bytes[table_offset_offset..][0..4], 0x2a80, .big);
    std.mem.writeInt(u64, alloc_bytes[body_offset_offset..][0..8], 0x2000, .big);
    std.mem.writeInt(u64, alloc_bytes[body_size_offset..][0..8], 0x2fe000, .big);
    std.mem.writeInt(u32, alloc_bytes[pfs_image_count_offset..][0..4], 1, .big);
    std.mem.writeInt(u64, alloc_bytes[pfs_image_offset_offset..][0..8], 0x300000, .big);
    std.mem.writeInt(u64, alloc_bytes[pfs_image_size_offset..][0..8], 0x06130000, .big);
    std.mem.writeInt(u64, alloc_bytes[mount_image_size_offset..][0..8], 0x06430000, .big);
    std.mem.writeInt(u64, alloc_bytes[package_size_offset..][0..8], 0x06430000, .big);
    std.mem.writeInt(u64, alloc_bytes[split_size_0_offset..][0..8], 0x1111, .big);
    std.mem.writeInt(u64, alloc_bytes[split_size_1_offset..][0..8], 0x2222, .big);
    return alloc_bytes;
}

test "parseHeader: reads the base sample header fields" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);

    const header = switch (parseHeader(bytes, 0x06430000)) {
        .ok => |h| h,
        .fail => |f| {
            std.debug.print("unexpected failure: {s}\n", .{reasonName(f.reason)});
            return error.UnexpectedFailure;
        },
    };

    try std.testing.expectEqualStrings("UP4040-CUSA00740_00-TERRARIA00000001", &header.content_id);
    try std.testing.expectEqual(@as(u32, 15), header.file_count);
    try std.testing.expectEqual(@as(u32, 32), header.entry_count);
    try std.testing.expectEqual(@as(u32, 0x2a80), header.table_offset);
    try std.testing.expectEqual(@as(u64, 0x2000), header.body_offset);
    try std.testing.expectEqual(@as(u64, 0x2fe000), header.body_size);
    try std.testing.expectEqual(@as(u32, 1), header.pfs_image_count);
    try std.testing.expectEqual(@as(u64, 0x300000), header.pfs_image_offset);
    try std.testing.expectEqual(@as(u64, 0x06130000), header.pfs_image_size);
    try std.testing.expectEqual(@as(u64, 0x06430000), header.package_size);
    try std.testing.expectEqual(@as(u64, 0x1111), header.split_sizes[0]);
    try std.testing.expectEqual(@as(u64, 0x2222), header.split_sizes[1]);
}

test "parseHeader: image end equals package size on the sample shape" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    const header = switch (parseHeader(bytes, 0x06430000)) {
        .ok => |h| h,
        .fail => return error.UnexpectedFailure,
    };
    try std.testing.expectEqual(header.package_size, header.pfs_image_offset + header.pfs_image_size);
}

test "parseHeader: rejects a file shorter than the header" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    switch (parseHeader(bytes[0..0x800], 0x800)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| {
            try std.testing.expectEqual(Reason.too_short, f.reason);
            try std.testing.expectEqual(@as(usize, 0x800), f.offset);
        },
    }
}

test "parseHeader: rejects a wrong magic" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    bytes[0] = 0x00;
    switch (parseHeader(bytes, 0x06430000)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| try std.testing.expectEqual(Reason.bad_magic, f.reason),
    }
}

test "parseHeader: rejects an image past the end of the file" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    switch (parseHeader(bytes, 0x06430000 - 1)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| {
            try std.testing.expectEqual(Reason.image_out_of_range, f.reason);
            try std.testing.expectEqual(pfs_image_size_offset, f.offset);
        },
    }
}

test "parseHeader: rejects an offset plus size that overflows" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    std.mem.writeInt(u64, bytes[pfs_image_offset_offset..][0..8], std.math.maxInt(u64), .big);
    switch (parseHeader(bytes, 0x06430000)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| try std.testing.expectEqual(Reason.image_out_of_range, f.reason),
    }
}

test "parseEntries: reads a table row in on-disk order" {
    var table: [entry_size * 2]u8 = @splat(0);
    std.mem.writeInt(u32, table[0..4], 0x1200, .big);
    std.mem.writeInt(u32, table[4..8], 0x6e, .big);
    std.mem.writeInt(u32, table[8..12], 0, .big);
    std.mem.writeInt(u32, table[12..16], 0, .big);
    std.mem.writeInt(u32, table[16..20], 0x5c60, .big);
    std.mem.writeInt(u32, table[20..24], 0x30e6, .big);

    var entries: [2]Entry = undefined;
    try parseEntries(&table, 0, &entries);
    try std.testing.expectEqual(@as(u32, 0x1200), entries[0].id);
    try std.testing.expectEqual(@as(u32, 0x6e), entries[0].filename_offset);
    try std.testing.expectEqual(@as(u32, 0x5c60), entries[0].offset);
    try std.testing.expectEqual(@as(u32, 0x30e6), entries[0].size);
    try std.testing.expectEqual(@as(u32, 0), entries[1].id);
}

test "parseEntries: rejects a table past the end" {
    var table: [entry_size]u8 = @splat(0);
    var entries: [2]Entry = undefined;
    try std.testing.expectError(error.BadOffset, parseEntries(&table, 0, &entries));
    try std.testing.expectError(error.BadOffset, parseEntries(&table, 0x1000, entries[0..1]));
}

test "content flags: delta and patch detection" {
    try std.testing.expect(isDeltaPatch(content_flag_delta_patch));
    try std.testing.expect(!isDeltaPatch(content_flag_first_patch));
    try std.testing.expect(isPatch(content_flag_first_patch));
    try std.testing.expect(isPatch(content_flag_subsequent_patch));
    try std.testing.expect(!isPatch(0x0A000000));
}
