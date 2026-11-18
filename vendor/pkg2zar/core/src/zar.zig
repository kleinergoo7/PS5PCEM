// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-FileCopyrightText: ZArchive by Exzap, MIT
// SPDX-License-Identifier: GPL-3.0-or-later

//! ZArchive (.zar) writer and verification reader. Port of ZArchive by Exzap (MIT).
//! All multi-byte fields on disk are big-endian; file paths are compared case-insensitively.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const block_size: usize = 64 * 1024;
pub const entries_per_record: usize = 16;
pub const footer_size: usize = 144;
pub const footer_magic: u32 = 0x169f52d6;
pub const footer_version: u32 = 0x61bf3a01;

extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_compress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize, level: c_int) usize;
extern fn ZSTD_decompress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;

pub const zstd_level: c_int = 6;

pub const Error = error{
    PathNotFound,
    DuplicateEntry,
    NotAFile,
    WriteFailed,
    OutOfMemory,
    CompressionFailed,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.PathNotFound => "parent directory does not exist in the archive",
        error.DuplicateEntry => "entry already exists in the archive",
        error.NotAFile => "entry is not a file",
        error.WriteFailed => "write to the output failed",
        error.OutOfMemory => "out of memory",
        error.CompressionFailed => "zstd compression failed",
    };
}

const Node = struct {
    name: []const u8,
    parent: u32,
    is_file: bool,
    children: std.ArrayListUnmanaged(u32) = .empty,
    file_offset: u64 = 0,
    file_size: u64 = 0,
    start_index: u32 = 0,
};

pub const Writer = struct {
    io: std.Io,
    file: std.Io.File,
    arena: std.mem.Allocator,
    out_offset: u64 = 0,
    hasher: Sha256 = Sha256.init(.{}),
    buffer: [block_size]u8 = undefined,
    buffered: usize = 0,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    name_map: std.StringHashMapUnmanaged(u32) = .empty,
    record_bases: std.ArrayListUnmanaged(u64) = .empty,
    block_sizes: std.ArrayListUnmanaged(u16) = .empty,
    current_file: ?u32 = null,
    input_offset: u64 = 0,

    pub fn init(io: std.Io, file: std.Io.File, arena: std.mem.Allocator) !Writer {
        var w: Writer = .{ .io = io, .file = file, .arena = arena };
        try w.nodes.append(arena, .{ .name = "", .parent = 0, .is_file = false });
        return w;
    }

    pub fn makeDir(self: *Writer, path: []const u8) Error!void {
        var current: u32 = 0;
        var it = PathIterator{ .path = path };
        while (it.next()) |name| {
            if (name.len == 0) continue;
            if (try self.findChild(current, name)) |child| {
                if (self.nodes.items[child].is_file) return error.NotAFile;
                current = child;
                continue;
            }
            current = try self.addNode(current, name, false);
        }
    }

    pub fn startFile(self: *Writer, path: []const u8) Error!void {
        var parent_path: []const u8 = "";
        var filename: []const u8 = path;
        if (std.mem.lastIndexOfAny(u8, path, "/\\")) |slash| {
            parent_path = path[0..slash];
            filename = path[slash + 1 ..];
        }
        try self.makeDir(parent_path);

        const parent = try self.nodeByPath(parent_path) orelse return error.PathNotFound;
        if (try self.findChild(parent, filename)) |_| return error.DuplicateEntry;
        const node = try self.addNode(parent, filename, true);
        self.nodes.items[node].file_offset = self.input_offset;
        self.current_file = node;
    }

    pub fn appendData(self: *Writer, data: []const u8) Error!void {
        var rest = data;
        while (rest.len > 0) {
            const room = block_size - self.buffered;
            if (rest.len >= room) {
                @memcpy(self.buffer[self.buffered..][0..room], rest[0..room]);
                self.buffered = 0;
                rest = rest[room..];
                try self.storeBlock(&self.buffer);
                continue;
            }
            @memcpy(self.buffer[self.buffered..][0..rest.len], rest);
            self.buffered += rest.len;
            break;
        }
        if (self.current_file) |node| self.nodes.items[node].file_size += data.len;
        self.input_offset += data.len;
    }

    pub fn finalize(self: *Writer) Error!void {
        self.current_file = null;
        if (self.buffered > 0) {
            @memset(self.buffer[self.buffered..], 0);
            self.buffered = 0;
            try self.storeBlock(&self.buffer);
        }
        // The reference records the compressed-data size before the 8-byte padding; using the
        // padded offset makes a valid archive differ from it by one byte in the footer.
        const data_size = self.out_offset;
        while (self.out_offset % 8 != 0) try self.output(&[_]u8{0});

        const offset_records_offset = self.out_offset;
        try self.writeOffsetRecords();
        const offset_records_size = self.out_offset - offset_records_offset;

        const names_offset = self.out_offset;
        try self.writeNameTable();
        const names_size = self.out_offset - names_offset;

        const tree_offset = self.out_offset;
        try self.writeFileTree();
        const tree_size = self.out_offset - tree_offset;

        const meta_offset = self.out_offset;

        const total_size = self.out_offset + footer_size;
        var footer: [footer_size]u8 = @splat(0);
        // Layout matches the reference struct: six offset/size pairs, then the integrity
        // hash, then total size, version and magic.
        writeU64(&footer, 0, 0); // compressed data offset
        writeU64(&footer, 8, data_size); // compressed data size, before the padding
        writeU64(&footer, 16, offset_records_offset);
        writeU64(&footer, 24, offset_records_size);
        writeU64(&footer, 32, names_offset);
        writeU64(&footer, 40, names_size);
        writeU64(&footer, 48, tree_offset);
        writeU64(&footer, 56, tree_size);
        writeU64(&footer, 64, meta_offset);
        writeU64(&footer, 72, 0);
        writeU64(&footer, 80, meta_offset);
        writeU64(&footer, 88, 0);
        writeU64(&footer, 128, total_size);
        writeU32(&footer, 136, footer_version);
        writeU32(&footer, 140, footer_magic);

        var tmp = footer;
        self.hasher.update(&tmp);
        var hash: [32]u8 = undefined;
        Sha256.final(&self.hasher, &hash);
        @memcpy(footer[96..128], &hash);

        try self.outputRaw(&footer, false);
    }

    fn storeBlock(self: *Writer, block: *const [block_size]u8) Error!void {
        const base = self.out_offset;
        var compressed: [block_size + block_size / 2]u8 = undefined;
        const bound = ZSTD_compressBound(block_size);
        std.debug.assert(bound <= compressed.len);
        const out_size = ZSTD_compress(compressed[0..].ptr, compressed.len, block, block_size, zstd_level);
        if (ZSTD_isError(out_size) != 0) return error.CompressionFailed;

        var stored_size: usize = out_size;
        const raw: []const u8 = if (out_size >= block_size) blk: {
            stored_size = block_size;
            break :blk block;
        } else compressed[0..out_size];
        try self.output(raw);

        if (self.block_sizes.items.len % entries_per_record == 0) try self.record_bases.append(self.arena, base);
        try self.block_sizes.append(self.arena, @intCast(stored_size - 1));
    }

    fn writeOffsetRecords(self: *Writer) Error!void {
        for (self.record_bases.items, 0..) |base, i| {
            var record: [8 + 2 * entries_per_record]u8 = undefined;
            writeU64(&record, 0, base);
            for (0..entries_per_record) |j| {
                const idx = i * entries_per_record + j;
                const size: u16 = if (idx < self.block_sizes.items.len) self.block_sizes.items[idx] else 0;
                writeU16(&record, 8 + j * 2, size);
            }
            try self.output(&record);
        }
    }

    fn writeNameTable(self: *Writer) Error!void {
        for (self.names.items) |name| {
            const capped = name[0..@min(name.len, 0x7FFF)];
            if (capped.len >= 0x80) {
                const header = [2]u8{ @as(u8, @intCast(capped.len & 0x7F)) | 0x80, @intCast(capped.len >> 7) };
                try self.output(&header);
            } else {
                const header = [1]u8{@intCast(capped.len)};
                try self.output(&header);
            }
            try self.output(capped);
        }
    }

    fn writeFileTree(self: *Writer) Error!void {
        // Pass 1: assign node ranges, sorting each directory's children case-insensitively.
        var queue: std.ArrayListUnmanaged(u32) = .empty;
        defer queue.deinit(self.arena);
        try queue.append(self.arena, 0);
        var current_index: u32 = 1;
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node_idx = queue.items[head];
            const node = &self.nodes.items[node_idx];
            if (node.is_file) {
                node.start_index = 0xFFFFFFFF;
                continue;
            }
            std.mem.sort(u32, node.children.items, self, nodeLessThan);
            node.start_index = current_index;
            current_index += @intCast(node.children.items.len);
            try queue.appendSlice(self.arena, node.children.items);
        }

        // Pass 2: serialize in the same breadth-first order.
        queue.clearRetainingCapacity();
        head = 0;
        try queue.append(self.arena, 0);
        while (head < queue.items.len) : (head += 1) {
            const node_idx = queue.items[head];
            const node = self.nodes.items[node_idx];
            var entry: [16]u8 = @splat(0);
            const name_offset: u32 = if (node_idx == 0) 0x7FFFFFFF else try self.nameOffset(node.name);
            const type_flag: u32 = if (node.is_file) 0x80000000 else 0;
            writeU32(&entry, 0, type_flag | name_offset);
            if (node.is_file) {
                writeU32(&entry, 4, @truncate(node.file_offset));
                writeU32(&entry, 8, @truncate(node.file_size));
                const high: u32 = (@as(u32, @intCast(node.file_size >> 16)) & 0xFFFF0000) |
                    @as(u32, @intCast((node.file_offset >> 32) & 0xFFFF));
                writeU32(&entry, 12, high);
            } else {
                writeU32(&entry, 4, node.start_index);
                writeU32(&entry, 8, @intCast(node.children.items.len));
                writeU32(&entry, 12, 0);
            }
            try self.output(&entry);
            if (!node.is_file) try queue.appendSlice(self.arena, node.children.items);
        }
    }

    fn nameOffset(self: *Writer, name: []const u8) Error!u32 {
        for (self.names.items, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) {
                var offset: u32 = 0;
                for (self.names.items[0..i]) |n| {
                    const capped = @min(n.len, 0x7FFF);
                    offset += @intCast(if (capped >= 0x80) capped + 2 else capped + 1);
                }
                return offset;
            }
        }
        return error.PathNotFound;
    }

    fn addNode(self: *Writer, parent: u32, name: []const u8, is_file: bool) Error!u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena, .{
            .name = try self.arena.dupe(u8, name),
            .parent = parent,
            .is_file = is_file,
        });
        try self.nodes.items[parent].children.append(self.arena, idx);

        // The reference keys its name table on the exact string, so `Default.png` and
        // `default.png` are two entries even though directory lookups ignore case.
        try self.name_map.put(self.arena, try self.arena.dupe(u8, name), idx);

        var exists = false;
        for (self.names.items) |n| {
            if (std.mem.eql(u8, n, name)) {
                exists = true;
                break;
            }
        }
        if (!exists) try self.names.append(self.arena, try self.arena.dupe(u8, name));
        return idx;
    }

    fn findChild(self: *Writer, parent: u32, name: []const u8) Error!?u32 {
        for (self.nodes.items[parent].children.items) |child| {
            if (std.ascii.eqlIgnoreCase(self.nodes.items[child].name, name)) return child;
        }
        return null;
    }

    fn nodeByPath(self: *Writer, path: []const u8) Error!?u32 {
        var current: u32 = 0;
        var it = PathIterator{ .path = path };
        while (it.next()) |name| {
            if (name.len == 0) continue;
            current = try self.findChild(current, name) orelse return null;
        }
        return current;
    }

    fn output(self: *Writer, data: []const u8) Error!void {
        try self.outputRaw(data, true);
    }

    fn outputRaw(self: *Writer, data: []const u8, hash: bool) Error!void {
        self.file.writeStreamingAll(self.io, data) catch return error.WriteFailed;
        if (hash) self.hasher.update(data);
        self.out_offset += data.len;
    }
};

fn nodeLessThan(ctx: *Writer, a: u32, b: u32) bool {
    return std.ascii.lessThanIgnoreCase(ctx.nodes.items[a].name, ctx.nodes.items[b].name);
}

const PathIterator = struct {
    path: []const u8,
    index: usize = 0,

    fn next(self: *PathIterator) ?[]const u8 {
        while (self.index < self.path.len and (self.path[self.index] == '/' or self.path[self.index] == '\\')) self.index += 1;
        if (self.index >= self.path.len) return null;
        const start = self.index;
        while (self.index < self.path.len and self.path[self.index] != '/' and self.path[self.index] != '\\') self.index += 1;
        return self.path[start..self.index];
    }
};

// ---- reader -------------------------------------------------------------------------

pub const Entry = struct {
    path: []const u8,
    offset: u64,
    size: u64,
    is_file: bool,
};

pub const Reader = struct {
    io: std.Io,
    file: std.Io.File,
    arena: std.mem.Allocator,
    records: []Record,
    names: []const u8,
    tree: []const u8,
    file_count: usize,
    data_size: u64,

    pub const Record = struct { base: u64, sizes: [entries_per_record]u16 };

    pub fn open(io: std.Io, file: std.Io.File, arena: std.mem.Allocator) !Reader {
        const file_size = try file.length(io);
        if (file_size <= footer_size) return error.Truncated;
        var footer: [footer_size]u8 = undefined;
        if (try file.readPositionalAll(io, &footer, file_size - footer_size) != footer_size) return error.Truncated;
        if (readU32(&footer, 140) != footer_magic) return error.BadMagic;
        if (readU32(&footer, 136) != footer_version) return error.BadVersion;
        if (readU64(&footer, 128) != file_size) return error.BadTotalSize;

        const data_offset = readU64(&footer, 0);
        const data_size = readU64(&footer, 8);
        const rec_offset = readU64(&footer, 16);
        const rec_size = readU64(&footer, 24);
        const names_offset = readU64(&footer, 32);
        const names_size = readU64(&footer, 40);
        const tree_offset = readU64(&footer, 48);
        const tree_size = readU64(&footer, 56);
        if (data_offset + data_size > file_size) return error.BadSection;
        if (rec_offset + rec_size > file_size) return error.BadSection;
        if (names_offset + names_size > file_size) return error.BadSection;
        if (tree_offset + tree_size > file_size) return error.BadSection;
        if (rec_size % (8 + 2 * entries_per_record) != 0) return error.BadSection;
        if (tree_size % 16 != 0) return error.BadSection;

        const rec_bytes = try arena.alloc(u8, @intCast(rec_size));
        if (try file.readPositionalAll(io, rec_bytes, rec_offset) != rec_bytes.len) return error.Truncated;
        const records = try arena.alloc(Record, rec_bytes.len / (8 + 2 * entries_per_record));
        for (records, 0..) |*record, i| {
            const base = i * (8 + 2 * entries_per_record);
            record.base = readU64(rec_bytes, base);
            for (0..entries_per_record) |j| record.sizes[j] = readU16(rec_bytes, base + 8 + j * 2);
        }

        const names = try arena.alloc(u8, @intCast(names_size));
        if (try file.readPositionalAll(io, names, names_offset) != names.len) return error.Truncated;
        const tree = try arena.alloc(u8, @intCast(tree_size));
        if (try file.readPositionalAll(io, tree, tree_offset) != tree.len) return error.Truncated;

        return .{
            .io = io,
            .file = file,
            .arena = arena,
            .records = records,
            .names = names,
            .tree = tree,
            .file_count = tree_size / 16,
            .data_size = data_size,
        };
    }

    pub fn entries(self: *Reader) ![]Entry {
        var out: std.ArrayListUnmanaged(Entry) = .empty;
        const root = try self.nodeAt(0);
        if (root.is_file) return error.BadTree;
        _ = try self.walk(0, "", &out);
        return out.toOwnedSlice(self.arena);
    }

    fn walk(self: *Reader, index: usize, parent: []const u8, out: *std.ArrayListUnmanaged(Entry)) !usize {
        const entry = try self.nodeAt(index);
        if (entry.is_file) return index + 1;
        if (index * 16 + 16 > self.tree.len) return error.BadTree;
        const first = readU32(self.tree, index * 16 + 4);
        const count = readU32(self.tree, index * 16 + 8);
        var visited: usize = 1;
        for (0..count) |k| {
            const child_index = first + k;
            if (child_index * 16 + 16 > self.tree.len) return error.BadTree;
            const child = try self.nodeAt(child_index);
            const name = try self.nameAt(readU32(self.tree, child_index * 16) & 0x7FFFFFFF);
            const path = if (parent.len == 0)
                try self.arena.dupe(u8, name)
            else
                try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ parent, name });
            if (child.is_file) {
                try out.append(self.arena, .{ .path = path, .offset = child.offset, .size = child.size, .is_file = true });
                visited += 1;
            } else {
                try out.append(self.arena, .{ .path = path, .offset = 0, .size = 0, .is_file = false });
                visited += 1;
                visited += try self.walk(child_index, path, out);
            }
        }
        return visited;
    }

    pub const FileNode = struct { offset: u64, size: u64, is_file: bool };

    fn nodeAt(self: *Reader, index: usize) !FileNode {
        if (index * 16 + 16 > self.tree.len) return error.BadTree;
        const flags = readU32(self.tree, index * 16);
        const is_file = flags & 0x80000000 != 0;
        if (!is_file) return .{ .offset = 0, .size = 0, .is_file = false };
        const low = readU32(self.tree, index * 16 + 4);
        const size_low = readU32(self.tree, index * 16 + 8);
        const high = readU32(self.tree, index * 16 + 12);
        const offset = @as(u64, low) | (@as(u64, high & 0xFFFF) << 32);
        const size = @as(u64, size_low) | (@as(u64, high & 0xFFFF0000) << 16);
        return .{ .offset = offset, .size = size, .is_file = true };
    }

    fn nameAt(self: *Reader, offset: u32) ![]const u8 {
        if (offset == 0x7FFFFFFF) return "";
        if (offset >= self.names.len) return error.BadNames;
        var pos: usize = offset;
        var len: u32 = self.names[pos] & 0x7F;
        if (self.names[pos] & 0x80 != 0) {
            if (pos + 1 >= self.names.len) return error.BadNames;
            // The writer stores the low seven bits in the first byte and bits 7.. in the
            // second, so a long name must be reassembled from `pos + 1`.
            len |= @as(u32, self.names[pos + 1]) << 7;
            pos += 2;
        } else pos += 1;
        if (pos + len > self.names.len) return error.BadNames;
        return self.names[pos .. pos + len];
    }

    /// Reads `entry.size` bytes of a file into `out`, decompressing blocks on the way.
    pub fn readFile(self: *Reader, entry: Entry, out: []u8) !void {
        if (!entry.is_file) return error.NotAFile;
        if (out.len < entry.size) return error.BufferTooSmall;
        var remaining: usize = @intCast(entry.size);
        var written: usize = 0;
        var block_index: usize = @intCast(entry.offset / block_size);
        const skip: usize = @intCast(entry.offset % block_size);
        var block_buf: [block_size]u8 = undefined;
        var first = true;
        while (remaining > 0) : (block_index += 1) {
            try self.readBlock(block_index, &block_buf);
            const start: usize = if (first) skip else 0;
            first = false;
            const take = @min(remaining, block_size - start);
            @memcpy(out[written..][0..take], block_buf[start..][0..take]);
            written += take;
            remaining -= take;
        }
    }

    /// Writes `entry.size` bytes to `file` one block at a time, so extracting a game archive
    /// never needs a buffer of the file's size.
    pub fn copyFile(self: *Reader, entry: Entry, file: std.Io.File) !void {
        if (!entry.is_file) return error.NotAFile;
        var remaining: usize = @intCast(entry.size);
        var block_index: usize = @intCast(entry.offset / block_size);
        const skip: usize = @intCast(entry.offset % block_size);
        var block_buf: [block_size]u8 = undefined;
        var first = true;
        while (remaining > 0) : (block_index += 1) {
            try self.readBlock(block_index, &block_buf);
            const start: usize = if (first) skip else 0;
            first = false;
            const take = @min(remaining, block_size - start);
            try file.writeStreamingAll(self.io, block_buf[start..][0..take]);
            remaining -= take;
        }
    }

    fn readBlock(self: *Reader, index: usize, out: *[block_size]u8) !void {
        const record_index = index / entries_per_record;
        const sub = index % entries_per_record;
        if (record_index >= self.records.len) return error.BadBlocks;
        const record = self.records[record_index];
        var offset = record.base;
        for (0..sub) |i| offset += @as(u64, record.sizes[i]) + 1;
        const compressed_size = @as(usize, record.sizes[sub]) + 1;
        if (offset + compressed_size > self.data_size) return error.BadBlocks;

        if (compressed_size == block_size) {
            if (try self.file.readPositionalAll(self.io, out, offset) != block_size) return error.Truncated;
            return;
        }
        var compressed: [block_size]u8 = undefined;
        if (try self.file.readPositionalAll(self.io, compressed[0..compressed_size], offset) != compressed_size) {
            return error.Truncated;
        }
        const n = ZSTD_decompress(out[0..].ptr, block_size, compressed[0..].ptr, compressed_size);
        if (ZSTD_isError(n) != 0 or n != block_size) return error.DecompressFailed;
    }
};

fn writeU16(dst: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, dst[offset..][0..2], value, .big);
}

fn writeU32(dst: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, dst[offset..][0..4], value, .big);
}

fn writeU64(dst: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, dst[offset..][0..8], value, .big);
}

fn readU16(src: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, src[offset..][0..2], .big);
}

fn readU32(src: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, src[offset..][0..4], .big);
}

fn readU64(src: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, src[offset..][0..8], .big);
}

test "zar writer round-trips files and directories" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = ".zig-cache/zar-roundtrip-test.zar";

    const created = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    {
        var writer = try Writer.init(io, created, arena);
        defer writer.nodes.deinit(arena);
        try writer.makeDir("sce_sys");
        try writer.makeDir("sce_sys/about");
        try writer.startFile("sce_sys/param.sfo");
        try writer.appendData("\x00PSFtest");
        try writer.startFile("eboot.bin");
        var thousand: [1000]u8 = @splat('x');
        try writer.appendData(&thousand);
        try writer.finalize();
    }
    created.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = try Reader.open(io, file, arena);
    const listing = try reader.entries();

    try std.testing.expectEqual(@as(usize, 4), listing.len);
    try std.testing.expectEqualStrings("eboot.bin", listing[0].path);
    try std.testing.expectEqualStrings("sce_sys", listing[1].path);
    try std.testing.expectEqualStrings("sce_sys/about", listing[2].path);
    try std.testing.expectEqualStrings("sce_sys/param.sfo", listing[3].path);

    const sfo = for (listing) |entry| {
        if (entry.is_file and std.mem.eql(u8, entry.path, "sce_sys/param.sfo")) break entry;
    } else return error.MissingEntry;
    try std.testing.expectEqual(@as(u64, 8), sfo.size);
    var buf: [8]u8 = undefined;
    try reader.readFile(sfo, &buf);
    try std.testing.expectEqualStrings("\x00PSFtest", &buf);

    const exe = for (listing) |entry| {
        if (entry.is_file and std.mem.eql(u8, entry.path, "eboot.bin")) break entry;
    } else return error.MissingEntry;
    const big = try arena.alloc(u8, 1000);
    defer arena.free(big);
    try reader.readFile(exe, big);
    const thousand: [1000]u8 = @splat('x');
    try std.testing.expectEqualSlices(u8, &thousand, big);
}

test "zar: a name longer than 127 bytes round-trips" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = ".zig-cache/zar-longname-test.zar";

    // 157 bytes, the shape of the longest names in a real game tree; the writer switches to
    // a two-byte length header at 128, which the reader used to decode from the wrong byte.
    const long_name = "models.building_blocks.vekta_hgh.vegetation.components.vegetation_vekta_hgh_trees_b001_c003_imposter.impostor_textures.model_impostor_normal_depth.corestream";
    try std.testing.expectEqual(@as(usize, 157), long_name.len);

    const created = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    {
        var writer = try Writer.init(io, created, arena);
        defer writer.nodes.deinit(arena);
        try writer.makeDir("lumps");
        const rel = try std.fmt.allocPrint(arena, "lumps/{s}", .{long_name});
        try writer.startFile(rel);
        try writer.appendData("payload");
        try writer.finalize();
    }
    created.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = try Reader.open(io, file, arena);
    const entries = try reader.entries();
    const expected = try std.fmt.allocPrint(arena, "lumps/{s}", .{long_name});
    var found = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, expected)) {
            found = true;
            try std.testing.expectEqual(@as(u64, 7), entry.size);
        }
    }
    try std.testing.expect(found);
}

test "zar copyFile writes the entry block by block" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = ".zig-cache/zar-copyfile-test.zar";
    const copy_path = ".zig-cache/zar-copyfile-test.bin";

    // Two blocks' worth plus a tail, so the loop takes more than one path through the records.
    const size = block_size + 7;
    const payload = try arena.alloc(u8, size);
    for (payload, 0..) |*byte, i| byte.* = @truncate(i * 31 + 7);

    const created = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    {
        var writer = try Writer.init(io, created, arena);
        defer writer.nodes.deinit(arena);
        try writer.startFile("data.bin");
        try writer.appendData(payload);
        try writer.finalize();
    }
    created.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = try Reader.open(io, file, arena);
    const listing = try reader.entries();
    const entry = for (listing) |item| {
        if (item.is_file) break item;
    } else return error.MissingEntry;
    try std.testing.expectEqual(@as(u64, size), entry.size);

    const copy = try std.Io.Dir.cwd().createFile(io, copy_path, .{ .truncate = true });
    try reader.copyFile(entry, copy);
    copy.close(io);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, copy_path, arena, .unlimited);
    try std.testing.expectEqualSlices(u8, payload, written);
}
