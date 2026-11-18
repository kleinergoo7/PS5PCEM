// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! PFSC walk: the compressed filesystem inside the PFS image. Produces the file list only;
//! streaming file data comes later. Ported from shadPS4 pkg.cpp (GPL-2.0-or-later).

const std = @import("std");

pub const pfsc_magic: u32 = 0x43534650; // "PFSC" in little-endian bytes
pub const block_size: usize = 0x10000;
pub const inode_stride: usize = 0xA8;
pub const inode_mode_offset: usize = 0x00;
pub const inode_size_offset: usize = 0x08;
pub const inode_blocks_offset: usize = 0x60;
pub const inode_loc_offset: usize = 0x64;

pub const dirent_type_file: u32 = 2;
pub const dirent_type_dir: u32 = 3;
pub const dirent_type_self: u32 = 4;
pub const dirent_type_parent: u32 = 5;

pub const Error = error{
    OutOfMemory,
    NoPfsc,
    BadPfscHeader,
    BlockOutOfRange,
    InflateFailed,
    MissingInode,
    BadDirent,
    BadSectorMap,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.NoPfsc => "no PFSC table found in the PFS image",
        error.BadPfscHeader => "PFSC header is inconsistent",
        error.BlockOutOfRange => "PFSC block offsets point outside the image",
        error.InflateFailed => "PFSC block failed to inflate",
        error.MissingInode => "directory entry refers to a missing inode",
        error.BadDirent => "malformed directory entry",
        error.BadSectorMap => "sector map block size is invalid",
    };
}

pub const Kind = enum { file, dir };

pub const Entry = struct {
    path: []const u8,
    inode: u32,
    kind: Kind,
    size: u64,
    blocks: u32,
    loc: u32,
};

pub const Inode = struct {
    mode: u16,
    size: u64,
    blocks: u32,
    loc: u32,
};

pub const Walk = struct {
    entries: []Entry,
    inodes: []Inode,
    pfsc_offset: usize,
    /// Raw sector map: block_count + 1 little-endian u64 offsets relative to the PFSC start.
    map: []const u8,
    block_count: usize,

    pub fn blockRange(self: Walk, index: usize) ?struct { start: u64, end: u64 } {
        if (index >= self.block_count) return null;
        return .{ .start = readU64(self.map, index * 8), .end = readU64(self.map, (index + 1) * 8) };
    }
};

pub const Layout = struct {
    pfsc_offset: usize,
    block_count: usize,
    /// Absolute offset of the sector map inside the PFS image, not inside the prefix.
    map_start: u64,
};

pub fn blockRange(map: []const u8, block_count: usize, index: usize) ?struct { start: u64, end: u64 } {
    if (index >= block_count) return null;
    return .{ .start = readU64(map, index * 8), .end = readU64(map, (index + 1) * 8) };
}

/// Reads PFSC blocks on demand. The returned slice must stay valid until the next call.
pub const BlockReader = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, index: usize) Error![]const u8,
};

/// Finds the PFSC table inside a decrypted prefix of the image and parses its header.
pub fn parseLayout(image: []const u8) Error!Layout {
    const pfsc_offset = findPfsc(image) orelse return error.NoPfsc;
    const header = image[pfsc_offset..];
    if (header.len < 0x30) return error.BadPfscHeader;
    const block_size2 = readU64(header, 0x10);
    const block_offsets = readU64(header, 0x18);
    const data_length = readU64(header, 0x28);
    if (block_size2 != block_size) return error.BadPfscHeader;

    const block_count: usize = @intCast(data_length / block_size2);
    const map_start = std.math.add(u64, @intCast(pfsc_offset), block_offsets) catch
        return error.BadPfscHeader;
    return .{
        .pfsc_offset = pfsc_offset,
        .block_count = block_count,
        .map_start = map_start,
    };
}

pub fn walk(arena: std.mem.Allocator, layout: Layout, map: []const u8, reader: BlockReader) Error!Walk {
    const pfsc_offset = layout.pfsc_offset;
    const block_count = layout.block_count;

    const block0 = try reader.read(reader.ctx, 0);
    const inode_count: usize = readU32(block0, 0x30);
    if (inode_count == 0) return error.BadPfscHeader;
    const inode_blocks = (inode_count * inode_stride + block_size - 1) / block_size;

    var inodes = try arena.alloc(Inode, inode_count);
    var inode_found: usize = 0;
    var b: usize = 1;
    while (b <= inode_blocks and b < block_count) : (b += 1) {
        const block = try reader.read(reader.ctx, b);
        var off: usize = 0;
        while (off + inode_stride <= block.len and inode_found < inode_count) : (off += inode_stride) {
            const mode = readU16(block, off + inode_mode_offset);
            if (mode == 0) break;
            inodes[inode_found] = .{
                .mode = mode,
                .size = @bitCast(readU64(block, off + inode_size_offset)),
                .blocks = readU32(block, off + inode_blocks_offset),
                .loc = readU32(block, off + inode_loc_offset),
            };
            inode_found += 1;
        }
    }
    if (inode_found != inode_count) return error.BadPfscHeader;
    inodes = inodes[0..inode_found];

    // Directory blocks: one block per directory that fits, continuation blocks for the
    // rest. Every group starts with ".<self>" then "..<parent>"; continuation blocks have
    // no header and are attached to the group being read.
    const DirGroup = struct {
        self_ino: u32,
        parent_ino: u32,
        children: std.ArrayListUnmanaged(Child) = .empty,
    };

    // File inodes claim their data blocks; whatever is left can only be metadata. Scanning
    // only the unclaimed blocks keeps a multi-GB image fast without skipping directories.
    const claimed = try arena.alloc(bool, block_count);
    @memset(claimed, false);
    for (inodes) |inode| {
        if (inode.mode & 0x8000 == 0) continue;
        var j: usize = 0;
        while (j < inode.blocks) : (j += 1) {
            const idx = @as(usize, inode.loc) + j;
            if (idx < block_count) claimed[idx] = true;
        }
    }

    var groups = std.ArrayListUnmanaged(DirGroup).empty;
    var current: ?usize = null;
    var block_index: usize = inode_blocks + 1;
    while (block_index < block_count) : (block_index += 1) {
        if (claimed[block_index]) continue;
        const raw = reader.read(reader.ctx, block_index) catch |err| switch (err) {
            error.BlockOutOfRange => break,
            else => return err,
        };
        if (direntGroupStart(raw)) |start| {
            try groups.append(arena, .{ .self_ino = start.self.ino, .parent_ino = start.parent.ino });
            current = groups.items.len - 1;
            try appendChildren(arena, raw, start.child_off, &groups.items[current.?].children);
        } else if (current) |ci| {
            const off = findEntryStart(raw) orelse continue;
            try appendChildren(arena, raw, off, &groups.items[ci].children);
        }
    }
    if (groups.items.len == 0) return error.BadDirent;

    // Directory names come from the parent's listing, never from the "." entry.
    const dir_parent = try arena.alloc(?u32, inode_count);
    const dir_name = try arena.alloc(?[]const u8, inode_count);
    @memset(dir_parent, null);
    @memset(dir_name, null);
    var root_ino: ?u32 = null;
    for (groups.items) |group| {
        if (group.parent_ino == group.self_ino) root_ino = group.self_ino;
        for (group.children.items) |child| {
            if (child.kind != dirent_type_dir) continue;
            if (child.ino >= inode_count) return error.MissingInode;
            dir_parent[child.ino] = group.self_ino;
            dir_name[child.ino] = try arena.dupe(u8, child.name);
        }
    }
    const root = root_ino orelse return error.BadDirent;

    const dir_paths = try arena.alloc(?[]const u8, inode_count);
    @memset(dir_paths, null);
    dir_paths[root] = "";
    var pass: usize = 0;
    while (pass <= inode_count) : (pass += 1) {
        var progress = false;
        for (groups.items) |group| {
            if (dir_paths[group.self_ino] != null) continue;
            const parent = dir_parent[group.self_ino] orelse continue;
            const parent_path = dir_paths[parent] orelse continue;
            const name = dir_name[group.self_ino] orelse continue;
            dir_paths[group.self_ino] = try joinPath(arena, parent_path, name);
            progress = true;
        }
        if (!progress) break;
    }

    var entries = std.ArrayList(Entry).empty;
    for (groups.items) |group| {
        const dir_path = dir_paths[group.self_ino] orelse return error.BadDirent;
        for (group.children.items) |child| {
            if (child.kind != dirent_type_file and child.kind != dirent_type_dir) continue;
            if (child.ino >= inode_count) return error.MissingInode;
            const inode = inodes[child.ino];
            if (inode.mode == 0) return error.MissingInode;
            const path = try joinPath(arena, dir_path, child.name);
            try entries.append(arena, .{
                .path = path,
                .inode = child.ino,
                .kind = if (child.kind == dirent_type_dir) .dir else .file,
                .size = inode.size,
                .blocks = inode.blocks,
                .loc = inode.loc,
            });
        }
    }

    return .{
        .entries = try entries.toOwnedSlice(arena),
        .inodes = inodes,
        .pfsc_offset = pfsc_offset,
        .map = map[0 .. (block_count + 1) * 8],
        .block_count = block_count,
    };
}

const Child = struct { ino: u32, kind: u32, name: []const u8 };

const GroupStart = struct {
    self: Dirent,
    parent: Dirent,
    child_off: usize,
};

fn direntGroupStart(block: []const u8) ?GroupStart {
    const self_entry = parseDirent(block, 0) catch return null;
    if (self_entry.type != dirent_type_self) return null;
    const parent_entry = parseDirent(block, self_entry.entsize) catch return null;
    if (parent_entry.type != dirent_type_parent) return null;
    return .{ .self = self_entry, .parent = parent_entry, .child_off = self_entry.entsize + parent_entry.entsize };
}

/// A continuation block may begin in the middle of an entry; find the first offset that
/// parses as two consecutive sane entries.
fn findEntryStart(block: []const u8) ?usize {
    var off: usize = 0;
    while (off < 64 and off + 16 <= block.len) : (off += 1) {
        const first = parseDirent(block, off) catch continue;
        if (first.ino == 0) continue;
        if (parseDirent(block, off + first.entsize)) |second| {
            if (second.ino != 0) return off;
        } else |_| {}
    }
    return null;
}

fn appendChildren(
    arena: std.mem.Allocator,
    block: []const u8,
    first_offset: usize,
    out: *std.ArrayListUnmanaged(Child),
) !void {
    var off = first_offset;
    while (off < block.len) {
        const dirent = parseDirent(block, off) catch break;
        off += dirent.entsize;
        if (dirent.type != dirent_type_file and dirent.type != dirent_type_dir) continue;
        try out.append(arena, .{
            .ino = dirent.ino,
            .kind = dirent.type,
            .name = try arena.dupe(u8, dirent.name),
        });
    }
}

const Dirent = struct {
    ino: u32,
    type: u32,
    entsize: usize,
    name: []const u8,
};

fn parseDirent(block: []const u8, offset: usize) Error!Dirent {
    if (offset + 16 > block.len) return error.BadDirent;
    const ino = readU32(block, offset);
    const kind = readU32(block, offset + 4);
    const namelen: usize = readU32(block, offset + 8);
    const entsize: usize = readU32(block, offset + 12);
    if (entsize < 16 + namelen or entsize > 16 + 512) return error.BadDirent;
    if (offset + entsize > block.len) return error.BadDirent;
    if (namelen == 0) return error.BadDirent;
    if (kind < dirent_type_file or kind > dirent_type_parent) return error.BadDirent;
    return .{
        .ino = ino,
        .type = kind,
        .entsize = entsize,
        .name = block[offset + 16 .. offset + 16 + namelen],
    };
}

fn joinPath(arena: std.mem.Allocator, parent: []const u8, name: []const u8) ![]const u8 {
    if (parent.len == 0) return arena.dupe(u8, name);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, name });
}

fn findPfsc(image: []const u8) ?usize {
    var offset: usize = 0x20000;
    while (offset + 4 <= image.len) : (offset += block_size) {
        if (readU32(image, offset) == pfsc_magic) return offset;
    }
    return null;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}
