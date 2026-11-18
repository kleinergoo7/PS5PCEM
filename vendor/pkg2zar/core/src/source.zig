// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! One pkg opened as a piece set: header, entry table, key material, decrypted PFS prefix,
//! and the walked file tree. Piece-aware reads make a split pkg look like one stream.

const std = @import("std");
const pkg = @import("pkg.zig");
const pfs = @import("pfs.zig");
const pieces = @import("pieces.zig");
const unpack = @import("unpack.zig");
const crypto = @import("crypto.zig");

pub const SceFile = struct {
    path: []const u8,
    entry: pkg.Entry,
};

pub const Fail = union(enum) {
    piece: pieces.Failure,
    open_failed: struct { path: []const u8, err: anyerror },
    header: struct { path: []const u8, reason: pkg.Reason, offset: usize },
    entry_table: struct { path: []const u8, offset: u64 },
    unpack: unpack.Error,
    walk: pfs.Error,
    truncated_image: struct { path: []const u8 },
    names_out_of_range: struct { path: []const u8 },
};

pub const Result = union(enum) {
    ok: Source,
    fail: Fail,
};

pub fn describe(fail: Fail, buf: []u8) []const u8 {
    return switch (fail) {
        .piece => |failure| pieces.describe(failure, buf),
        .open_failed => |f| std.fmt.bufPrint(buf, "{s}: cannot open: {t}", .{ f.path, f.err }) catch "cannot open pkg",
        .header => |f| std.fmt.bufPrint(buf, "{s}: {s} (at 0x{X})", .{ f.path, pkg.reasonName(f.reason), f.offset }) catch "bad pkg header",
        .entry_table => |f| std.fmt.bufPrint(buf, "{s}: entry table at 0x{X} is outside the file", .{ f.path, f.offset }) catch "bad entry table",
        .unpack => |e| unpack.reasonName(e),
        .walk => |e| pfs.reasonName(e),
        .truncated_image => |f| std.fmt.bufPrint(buf, "{s}: PFS image is shorter than declared", .{f.path}) catch "truncated image",
        .names_out_of_range => |f| std.fmt.bufPrint(buf, "{s}: entry name table is outside the file", .{f.path}) catch "bad name table",
    };
}

pub const Source = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    paths: []const []const u8,
    files: []std.Io.File,
    stream: pieces.Stream,
    header_bytes: [pkg.header_size]u8,
    header: pkg.Header,
    entries: []pkg.Entry,
    entry_names: []const u8,
    walk: pfs.Walk,
    keys: unpack.Keys = undefined,
    pfsc_offset: usize = 0,
    sector_map: []const u8 = &.{},
    block_count: usize = 0,
    cipher_scratch: []u8 = &.{},
    plain_scratch: []u8 = &.{},
    out_scratch: []u8 = &.{},

    pub fn open(io: std.Io, arena: std.mem.Allocator, paths: []const []const u8) error{OutOfMemory}!Result {
        const files = try arena.alloc(std.Io.File, paths.len);
        const inputs = try arena.alloc(pieces.Input, paths.len);
        var opened: usize = 0;
        errdefer closeAll(files[0..opened], io);

        for (paths, 0..) |path, i| {
            const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
                return .{ .fail = .{ .open_failed = .{ .path = path, .err = err } } };
            };
            files[i] = file;
            opened += 1;
            const size = file.length(io) catch |err| {
                return .{ .fail = .{ .open_failed = .{ .path = path, .err = err } } };
            };
            inputs[i] = .{ .path = path, .size = size };
        }

        const ordered = try pieces.order(arena, inputs);
        const ordered_pieces = switch (ordered) {
            .ok => |p| p,
            .fail => |failure| return .{ .fail = .{ .piece = failure } },
        };
        const sizes = try arena.alloc(u64, ordered_pieces.len);
        for (ordered_pieces, 0..) |piece, i| sizes[i] = piece.size;
        const stream = pieces.Stream.init(io, files, sizes);
        const file_size = stream.total;
        const first = paths[0];

        var source: Source = .{
            .io = io,
            .arena = arena,
            .paths = paths,
            .files = files,
            .stream = stream,
            .header_bytes = undefined,
            .header = undefined,
            .entries = undefined,
            .entry_names = &.{},
            .walk = undefined,
        };

        stream.readExact(io, 0, &source.header_bytes) catch
            return .{ .fail = .{ .truncated_image = .{ .path = first } } };
        source.header = switch (pkg.parseHeader(&source.header_bytes, file_size)) {
            .ok => |h| h,
            .fail => |failure| return .{ .fail = .{ .header = .{ .path = first, .reason = failure.reason, .offset = failure.offset } } },
        };

        const table_len = @as(u64, source.header.entry_count) * pkg.entry_size;
        const table_end = std.math.add(u64, source.header.table_offset, table_len) catch file_size + 1;
        if (table_end > file_size) {
            return .{ .fail = .{ .entry_table = .{ .path = first, .offset = source.header.table_offset } } };
        }
        const table = try arena.alloc(u8, @intCast(table_len));
        stream.readExact(io, source.header.table_offset, table) catch
            return .{ .fail = .{ .entry_table = .{ .path = first, .offset = source.header.table_offset } } };
        source.entries = try arena.alloc(pkg.Entry, source.header.entry_count);
        pkg.parseEntries(table, 0, source.entries) catch
            return .{ .fail = .{ .entry_table = .{ .path = first, .offset = source.header.table_offset } } };

        if (findEntry(source.entries, pkg.entry_id_entry_names)) |names_entry| {
            const end = std.math.add(u64, names_entry.offset, names_entry.size) catch file_size + 1;
            if (end > file_size) return .{ .fail = .{ .names_out_of_range = .{ .path = first } } };
            const names = try arena.alloc(u8, names_entry.size);
            stream.readExact(io, names_entry.offset, names) catch
                return .{ .fail = .{ .names_out_of_range = .{ .path = first } } };
            source.entry_names = names;
        }

        const keys = unpack.derive(stream, file_size, source.header, source.entries) catch |err|
            return .{ .fail = .{ .unpack = err } };
        source.keys = keys;

        const window_len: u64 = @as(u64, source.header.pfs_cache_size) * 2;
        const take: usize = @intCast(@min(window_len, source.header.pfs_image_size));
        const encrypted = try arena.alloc(u8, take);
        stream.readExact(io, source.header.pfs_image_offset, encrypted) catch
            return .{ .fail = .{ .truncated_image = .{ .path = first } } };
        const plain = try arena.alloc(u8, take);
        var sector: u64 = 0;
        var off: usize = 0;
        while (off < take) : (off += 0x1000) {
            const end = @min(off + 0x1000, take);
            crypto.xtsDecrypt(keys.data, keys.tweak, sector, encrypted[off..end], plain[off..end]);
            sector += 1;
        }

        const layout = pfs.parseLayout(plain) catch |err|
            return .{ .fail = .{ .walk = err } };
        const map_len = (layout.block_count + 1) * 8;
        const map_end = std.math.add(u64, layout.map_start, map_len) catch
            return .{ .fail = .{ .walk = error.BlockOutOfRange } };
        if (map_end > source.header.pfs_image_size) return .{ .fail = .{ .walk = error.BlockOutOfRange } };
        source.cipher_scratch = try arena.alloc(u8, 0x11000);
        source.plain_scratch = try arena.alloc(u8, 0x11000);
        source.out_scratch = try arena.alloc(u8, pfs.block_size);
        const map = source.decryptImageRange(layout.map_start, map_len) catch
            return .{ .fail = .{ .walk = error.BlockOutOfRange } };
        source.pfsc_offset = layout.pfsc_offset;
        source.sector_map = map;
        source.block_count = layout.block_count;
        source.walk = pfs.walk(arena, layout, map, .{ .ctx = &source, .read = readBlockThunk }) catch |err|
            return .{ .fail = .{ .walk = err } };

        return .{ .ok = source };
    }

    /// Decrypts `len` bytes at `rel` (offset inside the PFS image) into fresh arena memory.
    fn decryptImageRange(self: *Source, rel: u64, len: usize) ![]u8 {
        const aligned = rel & ~@as(u64, 0xFFF);
        const skip: usize = @intCast(rel - aligned);
        const span = skip + len;
        const sectors = (span + 0xFFF) / 0x1000;
        const want = @as(usize, @intCast(sectors)) * 0x1000;
        const cipher = try self.arena.alloc(u8, want);
        const plain = try self.arena.alloc(u8, want);
        try self.stream.readExact(self.io, self.header.pfs_image_offset + aligned, cipher);
        var s: usize = 0;
        while (s < want) : (s += 0x1000) {
            const sector_index = (aligned + s) / 0x1000;
            crypto.xtsDecrypt(self.keys.data, self.keys.tweak, sector_index, cipher[s..][0..0x1000], plain[s..][0..0x1000]);
        }
        return plain[skip..][0..len];
    }

    /// One decompressed PFSC block, by absolute block index inside the PFSC table.
    /// The returned slice is valid until the next block read.
    fn readBlockRaw(self: *Source, block_index: usize) pfs.Error![]const u8 {
        const range = pfs.blockRange(self.sector_map, self.block_count, block_index) orelse
            return error.BlockOutOfRange;
        if (range.end < range.start) return error.BadSectorMap;
        const size: usize = @intCast(range.end - range.start);
        if (size == 0 or size > pfs.block_size) return error.BadSectorMap;

        const rel = self.pfsc_offset + range.start;
        const aligned = rel & ~@as(u64, 0xFFF);
        const skip: usize = @intCast(rel - aligned);
        const want = ((skip + size + 0xFFF) / 0x1000) * 0x1000;
        std.debug.assert(want <= self.cipher_scratch.len);
        self.stream.readExact(self.io, self.header.pfs_image_offset + aligned, self.cipher_scratch[0..want]) catch
            return error.BlockOutOfRange;
        var s: usize = 0;
        while (s < want) : (s += 0x1000) {
            const sector_index = (aligned + s) / 0x1000;
            crypto.xtsDecrypt(self.keys.data, self.keys.tweak, sector_index, self.cipher_scratch[s..][0..0x1000], self.plain_scratch[s..][0..0x1000]);
        }
        const compressed = self.plain_scratch[skip..][0..size];
        if (size == pfs.block_size) return compressed;

        var in: std.Io.Reader = .fixed(compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &window);
        var writer: std.Io.Writer = .fixed(self.out_scratch);
        _ = decompress.reader.streamRemaining(&writer) catch return error.InflateFailed;
        if (writer.end == 0) return error.InflateFailed;
        return self.out_scratch[0..writer.end];
    }

    /// One decompressed PFSC block of a file, by block index within that file.
    pub fn readPfsBlock(self: *const Source, block_index: usize, out: *[pfs.block_size]u8) ![]const u8 {
        const data = try @constCast(self).readBlockRaw(block_index);
        if (data.len > out.len) return error.BadSectorMap;
        @memcpy(out[0..data.len], data);
        return out[0..data.len];
    }

    pub fn close(self: Source) void {
        closeAll(self.files, self.io);
    }

    /// sce_sys files that live in the pkg entry table rather than the PFS image.
    /// Every pkg entry as the mandate extractor writes it: `sce_sys/<table name>`, or
    /// `sce_sys/<decimal id>` for an id outside the table. Includes the metadata blobs.
    pub fn sceFiles(self: Source) ![]SceFile {
        var out: std.ArrayListUnmanaged(SceFile) = .empty;
        for (self.entries) |entry| {
            if (pkg.entryNameById(entry.id)) |name| {
                const path = try std.fmt.allocPrint(self.arena, "sce_sys/{s}", .{name});
                try out.append(self.arena, .{ .path = path, .entry = entry });
            } else {
                const path = try std.fmt.allocPrint(self.arena, "sce_sys/{d}", .{entry.id});
                try out.append(self.arena, .{ .path = path, .entry = entry });
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    /// Full contents of an sce_sys entry, decrypting the NP files (0x400-0x403) the way the
    /// reference implementation does. Allocated in the source arena.
    pub fn sceEntryData(self: *const Source, entry: pkg.Entry) ![]u8 {
        const buf = try self.arena.alloc(u8, entry.size);
        if (!pkg.entryNeedsDecryption(entry.id)) {
            try self.stream.readExact(self.io, entry.offset, buf);
            return buf;
        }
        const padded_len = (entry.size + 15) & ~@as(usize, 15);
        const cipher = try self.arena.alloc(u8, padded_len);
        @memset(cipher, 0);
        // Match the reference implementation: only the stored bytes are read, the rest of
        // the final block stays zero. The unscrambled tail bytes are padding, not content.
        try self.stream.readExact(self.io, entry.offset, cipher[0..entry.size]);

        var raw: [32]u8 = undefined;
        std.mem.writeInt(u32, raw[0..4], entry.id, .big);
        std.mem.writeInt(u32, raw[4..8], entry.filename_offset, .big);
        std.mem.writeInt(u32, raw[8..12], entry.flags1, .big);
        std.mem.writeInt(u32, raw[12..16], entry.flags2, .big);
        std.mem.writeInt(u32, raw[16..20], entry.offset, .big);
        std.mem.writeInt(u32, raw[20..24], entry.size, .big);
        @memset(raw[24..32], 0);
        var hashed: [64]u8 = undefined;
        @memcpy(hashed[0..32], &raw);
        @memcpy(hashed[32..], &self.keys.dk3);
        const iv_key = crypto.sha256(&hashed);

        const plain = try self.arena.alloc(u8, padded_len);
        crypto.aesCbcDecrypt(iv_key[16..32].*, iv_key[0..16].*, cipher, plain);
        @memcpy(buf, plain[0..entry.size]);
        return buf;
    }

    fn entryName(self: Source, entry: pkg.Entry) ?[]const u8 {
        const offset: usize = entry.filename_offset;
        if (offset == 0 or offset >= self.entry_names.len) return null;
        const rest = self.entry_names[offset..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        if (end == 0) return null;
        return rest[0..end];
    }

    pub fn contentId(self: *const Source) []const u8 {
        return std.mem.trimEnd(u8, &self.header.content_id, "\x00 ");
    }

    /// `CUSAxxxxx`, the nine characters after the entitlement prefix and dash.
    pub fn titleId(self: *const Source) ?[]const u8 {
        const id = self.contentId();
        if (id.len < 16 or id[6] != '-') return null;
        return id[7..16];
    }

    /// `UP4040`, `EP....`, the part before the dash.
    pub fn entitlement(self: *const Source) ?[]const u8 {
        const id = self.contentId();
        if (id.len < 7 or id[6] != '-') return null;
        return id[0..6];
    }

    pub fn fileSize(self: *const Source) u64 {
        return self.stream.total;
    }
};

fn readBlockThunk(ctx: *anyopaque, index: usize) pfs.Error![]const u8 {
    const self: *Source = @ptrCast(@alignCast(ctx));
    return self.readBlockRaw(index);
}

fn findEntry(entries: []const pkg.Entry, id: u32) ?pkg.Entry {
    for (entries) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

fn closeAll(files: []std.Io.File, io: std.Io) void {
    for (files) |file| file.close(io);
}

test "contentId, titleId and entitlement parse the sample layout" {
    var source: Source = undefined;
    @memset(&source.header.content_id, 0);
    @memcpy(source.header.content_id[0..36], "UP4040-CUSA00740_00-TERRARIA00000001");
    try std.testing.expectEqualStrings("UP4040-CUSA00740_00-TERRARIA00000001", (&source).contentId());
    try std.testing.expectEqualStrings("CUSA00740", (&source).titleId().?);
    try std.testing.expectEqualStrings("UP4040", (&source).entitlement().?);
}
