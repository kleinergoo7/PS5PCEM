// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Builds a synthetic pkg in memory: no game data, no retail key. Every layer the reader
//! walks is present: header, plaintext entry table, RSA-wrapped key material, XTS image with
//! a PFSC tree, and a param.sfo. Tests use it to run plan, export and extract without a ROM.

const std = @import("std");
const pkg = @import("pkg.zig");
const crypto = @import("crypto.zig");
const pfs = @import("pfs.zig");
const psf = @import("psf.zig");
const source = @import("source.zig");
const plan_mod = @import("plan.zig");
const exporter = @import("export.zig");
const extractor = @import("extract.zig");
const zar = @import("zar.zig");
const probe = @import("probe.zig");

pub const Options = struct {
    /// Exactly 36 bytes: 6-byte entitlement, '-', 9-byte title id, then free text.
    content_id: []const u8 = "UP0000-CUSA00000_00-P2ZSYNTHETIC0001",
    content_flags: u32 = 0,
    title: []const u8 = "Synthetic Game",
    app_ver: []const u8 = "01.00",
    /// Extra bytes in eboot.bin, so a base and an update differ in content, not just flags.
    eboot_fill: usize = 0,
};

const header_size = pkg.header_size;
const table_offset = 0x1000;
const entry_count = 4;
const body_offset = 0x2000;
const keyset_offset = body_offset;
const keyset_size = 0x800;
const image_key_offset = keyset_offset + keyset_size;
const image_key_size = 0x100;
const sfo_offset = image_key_offset + image_key_size;
const names_offset = 0x3000;
const entry_names = "\x00param.sfo\x00";
const pfs_offset = 0x40000;
const pfsc_offset = 0x20000;
const block = pfs.block_size;
const inode_count = 6;
const block_count = 9;
const map_offset = block_count * block;
const image_size = pfsc_offset + map_offset + 0x1000;
const package_size = pfs_offset + image_size;

// Fixed key material: the generator picks it, so no retail value is involved.
const dk3: [32]u8 = @splat(0x11);
const ekpfs: [32]u8 = @splat(0x22);
const seed: [16]u8 = @splat(0x33);

const media = struct {
    const eboot = "SYNTHETIC-EBOOT\n";
    const readme = "readme\n";
    const notes = "notes\n";
    const icon = "\x89PNG-synthetic";
};

pub fn build(arena: std.mem.Allocator, options: Options) ![]u8 {
    if (options.content_id.len != pkg.content_id_len) return error.BadContentId;

    const sfo = try paramSfo(arena, options);
    if (sfo_offset + sfo.len > pfs_offset) return error.SfoTooBig;

    const data = try arena.alloc(u8, package_size);
    @memset(data, 0);

    writeHeader(data, sfo.len, options);
    writeEntry(data, 0, .{ .id = pkg.entry_id_entry_keys, .offset = keyset_offset, .size = keyset_size });
    writeEntry(data, 1, .{ .id = pkg.entry_id_image_key, .offset = image_key_offset, .size = image_key_size });
    writeEntry(data, 2, .{ .id = pkg.entry_id_entry_names, .offset = names_offset, .size = entry_names.len });
    writeEntry(data, 3, .{ .id = pkg.entry_id_param_sfo, .offset = sfo_offset, .size = @intCast(sfo.len), .filename_offset = 1 });
    @memcpy(data[sfo_offset..][0..sfo.len], sfo);
    @memcpy(data[names_offset..][0..entry_names.len], entry_names);

    const image = data[pfs_offset..][0..image_size];
    buildImage(image, options.eboot_fill);

    // dk3 travels in keyset blob 3; ekpfs is AES-wrapped under a key that depends on the
    // image-key row and dk3, exactly as unpack.derive unwraps it.
    var dk3_cipher: [256]u8 = undefined;
    try rsaEncrypt(crypto.pkg_key_set, &dk3, &dk3_cipher);
    @memcpy(data[keyset_offset + 256 + 3 * 256 ..][0..256], &dk3_cipher);

    const row = entryRow(.{ .id = pkg.entry_id_image_key, .offset = image_key_offset, .size = image_key_size });
    var hashed: [64]u8 = undefined;
    @memcpy(hashed[0..32], &row);
    @memcpy(hashed[32..], &dk3);
    const iv_key = crypto.sha256(&hashed);

    var ekpfs_cipher: [256]u8 = undefined;
    try rsaEncrypt(crypto.fake_key_set, &ekpfs, &ekpfs_cipher);
    var img_key: [256]u8 = undefined;
    aesCbcEncrypt(iv_key[16..32].*, iv_key[0..16].*, &ekpfs_cipher, &img_key);
    @memcpy(data[image_key_offset..][0..image_key_size], &img_key);

    // Sector 0 stays readable: unpack.derive reads the PFS seed there without decrypting.
    var input: [20]u8 = undefined;
    std.mem.writeInt(u32, input[0..4], 1, .little);
    @memcpy(input[4..], &seed);
    const digest = crypto.hmacSha256(&ekpfs, &input);

    var sector_index: u64 = 1;
    while (sector_index * 0x1000 < image_size) : (sector_index += 1) {
        const start: usize = @intCast(sector_index * 0x1000);
        var plain: [0x1000]u8 = undefined;
        @memcpy(&plain, image[start..][0..0x1000]);
        xtsEncrypt(digest[16..32].*, digest[0..16].*, sector_index, &plain, image[start..][0..0x1000]);
    }
    return data;
}

fn writeHeader(data: []u8, sfo_len: usize, options: Options) void {
    @memcpy(data[0..4], &pkg.magic);
    @memcpy(data[pkg.content_id_offset..][0..pkg.content_id_len], options.content_id);
    writeU32be(data, pkg.file_count_offset, 4);
    writeU32be(data, pkg.entry_count_offset, entry_count);
    writeU32be(data, pkg.table_offset_offset, table_offset);
    writeU64be(data, pkg.body_offset_offset, body_offset);
    writeU64be(data, pkg.body_size_offset, pfs_offset - body_offset);
    writeU32be(data, pkg.content_type_offset, plan_mod.game_content_type);
    writeU32be(data, pkg.content_flags_offset, options.content_flags);
    writeU32be(data, pkg.pfs_image_count_offset, 1);
    writeU64be(data, pkg.pfs_image_offset_offset, pfs_offset);
    writeU64be(data, pkg.pfs_image_size_offset, image_size);
    writeU64be(data, pkg.mount_image_size_offset, package_size);
    writeU64be(data, pkg.package_size_offset, package_size);
    writeU32be(data, pkg.pfs_signed_size_offset, @intCast(image_size));
    writeU32be(data, pkg.pfs_cache_size_offset, 0x20000);
    _ = sfo_len;
}

const Row = struct { id: u32, filename_offset: u32 = 0, offset: usize, size: u32 };

fn entryRow(row: Row) [32]u8 {
    var out: [32]u8 = @splat(0);
    writeU32be(&out, 0, row.id);
    writeU32be(&out, 4, row.filename_offset);
    writeU32be(&out, 16, @intCast(row.offset));
    writeU32be(&out, 20, row.size);
    return out;
}

fn writeEntry(data: []u8, index: usize, row: Row) void {
    const off = table_offset + index * pkg.entry_size;
    @memcpy(data[off..][0..32], &entryRow(row));
}

fn buildImage(image: []u8, eboot_fill: usize) void {
    @memset(image, 0);
    @memcpy(image[0x370..][0..16], &seed);

    const pfsc = image[pfsc_offset..][0 .. block_count * block];
    writeU32(pfsc, 0x00, pfs.pfsc_magic);
    writeU64(pfsc, 0x10, block);
    writeU64(pfsc, 0x18, map_offset);
    writeU64(pfsc, 0x28, block_count * block);
    writeU32(pfsc, 0x30, inode_count);

    // Inodes: root, sce_sys, and four files. Each file owns one data block.
    writeInode(pfsc[block..][0..block], 0, .{ .mode = 0x41FF, .size = 0, .blocks = 0, .loc = 0 });
    writeInode(pfsc[block..][0..block], 1, .{ .mode = 0x41FF, .size = 0, .blocks = 0, .loc = 0 });
    writeInode(pfsc[block..][0..block], 2, .{ .mode = 0x81A4, .size = media.eboot.len + eboot_fill, .blocks = 1, .loc = 5 });
    writeInode(pfsc[block..][0..block], 3, .{ .mode = 0x81A4, .size = media.readme.len, .blocks = 1, .loc = 6 });
    writeInode(pfsc[block..][0..block], 4, .{ .mode = 0x81A4, .size = media.notes.len, .blocks = 1, .loc = 7 });
    writeInode(pfsc[block..][0..block], 5, .{ .mode = 0x81A4, .size = media.icon.len, .blocks = 1, .loc = 8 });

    // Root listing: the first block ends after eboot.bin, a continuation block carries the
    // rest, which is the shape real pkg directories have once they outgrow one block.
    writeDirents(pfsc[2 * block ..][0..block], &.{
        .{ .ino = 0, .kind = pfs.dirent_type_self, .name = "." },
        .{ .ino = 0, .kind = pfs.dirent_type_parent, .name = ".." },
        .{ .ino = 1, .kind = pfs.dirent_type_dir, .name = "sce_sys" },
        .{ .ino = 2, .kind = pfs.dirent_type_file, .name = "eboot.bin" },
    });
    writeDirents(pfsc[3 * block ..][0..block], &.{
        .{ .ino = 3, .kind = pfs.dirent_type_file, .name = "readme.txt" },
        .{ .ino = 4, .kind = pfs.dirent_type_file, .name = "notes.txt" },
    });
    writeDirents(pfsc[4 * block ..][0..block], &.{
        .{ .ino = 1, .kind = pfs.dirent_type_self, .name = "." },
        .{ .ino = 0, .kind = pfs.dirent_type_parent, .name = ".." },
        .{ .ino = 5, .kind = pfs.dirent_type_file, .name = "icon0.png" },
    });

    const eboot = pfsc[5 * block ..][0..block];
    @memcpy(eboot[0..media.eboot.len], media.eboot);
    for (eboot[media.eboot.len..][0..eboot_fill]) |*b| b.* = 'F';
    @memcpy(pfsc[6 * block ..][0..media.readme.len], media.readme);
    @memcpy(pfsc[7 * block ..][0..media.notes.len], media.notes);
    @memcpy(pfsc[8 * block ..][0..media.icon.len], media.icon);

    // Sector map: block i starts at i * 64 KiB, relative to the PFSC table. Blocks are
    // stored uncompressed, which is the `size == block_size` path of the reader.
    const map = image[pfsc_offset + map_offset ..];
    var index: usize = 0;
    while (index <= block_count) : (index += 1) {
        writeU64(map, index * 8, index * block);
    }
}

const Inode = struct { mode: u16, size: usize, blocks: u32, loc: u32 };

fn writeInode(block_bytes: []u8, index: usize, inode: Inode) void {
    const off = index * pfs.inode_stride;
    writeU16(block_bytes, off + pfs.inode_mode_offset, inode.mode);
    writeU64(block_bytes, off + pfs.inode_size_offset, inode.size);
    writeU32(block_bytes, off + pfs.inode_blocks_offset, inode.blocks);
    writeU32(block_bytes, off + pfs.inode_loc_offset, inode.loc);
}

const Dirent = struct { ino: u32, kind: u32, name: []const u8 };

fn writeDirents(target: []u8, list: []const Dirent) void {
    var off: usize = 0;
    for (list) |dirent| {
        const entsize = std.mem.alignForward(usize, 16 + dirent.name.len, 4);
        writeU32(target, off, dirent.ino);
        writeU32(target, off + 4, dirent.kind);
        writeU32(target, off + 8, @intCast(dirent.name.len));
        writeU32(target, off + 12, @intCast(entsize));
        @memcpy(target[off + 16 ..][0..dirent.name.len], dirent.name);
        off += entsize;
    }
}

/// A minimal `param.sfo`, also used by the folder-probe tests.
pub fn paramSfo(arena: std.mem.Allocator, options: Options) ![]u8 {
    const keys = "TITLE\x00APP_VER\x00";
    var values = std.ArrayList(u8).empty;
    defer values.deinit(arena);
    try values.appendSlice(arena, options.title);
    try values.append(arena, 0);
    const version_at = values.items.len;
    try values.appendSlice(arena, options.app_ver);
    try values.append(arena, 0);

    const count = 2;
    const key_table = 0x14 + count * 16;
    const data_table = key_table + keys.len;
    const out = try arena.alloc(u8, data_table + values.items.len);
    @memset(out, 0);
    @memcpy(out[0..4], &psf.magic);
    writeU32(out, 8, key_table);
    writeU32(out, 12, data_table);
    writeU32(out, 16, count);

    writeU16(out, 0x14, 0);
    writeU16(out, 0x16, psf.format_utf8);
    writeU32(out, 0x18, @intCast(options.title.len + 1));
    writeU32(out, 0x20, 0);

    writeU16(out, 0x24, 6);
    writeU16(out, 0x26, psf.format_utf8);
    writeU32(out, 0x28, @intCast(options.app_ver.len + 1));
    writeU32(out, 0x30, @intCast(version_at));

    @memcpy(out[key_table..][0..keys.len], keys);
    @memcpy(out[data_table..][0..values.items.len], values.items);
    return out;
}

fn rsaEncrypt(comptime key: anytype, message: []const u8, out: *[256]u8) !void {
    var em: [256]u8 = @splat(0);
    em[0] = 0x00;
    em[1] = 0x02;
    const ps_len = 256 - 3 - message.len;
    // Deterministic filler: the padding only has to be non-zero and long enough.
    for (em[2..][0..ps_len]) |*byte| byte.* = 0xA5;
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len ..][0..message.len], message);

    const Modulus = std.crypto.ff.Modulus(2048);
    const Fe = Modulus.Fe;
    const modulus = Modulus.fromBytes(key.modulus, .big) catch return error.RsaFailed;
    const m = Fe.fromBytes(modulus, &em, .big) catch return error.RsaFailed;
    const c = modulus.powWithEncodedPublicExponent(m, &.{ 0x01, 0x00, 0x01 }, .big) catch
        return error.RsaFailed;
    c.toBytes(out, .big) catch return error.RsaFailed;
}

fn aesCbcEncrypt(key: [16]u8, iv: [16]u8, src: []const u8, dst: []u8) void {
    std.debug.assert(src.len == dst.len and src.len % 16 == 0);
    const ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var prev = iv;
    var i: usize = 0;
    while (i < src.len) : (i += 16) {
        var x: [16]u8 = undefined;
        for (0..16) |b| x[b] = src[i + b] ^ prev[b];
        var c: [16]u8 = undefined;
        ctx.encrypt(&c, &x);
        @memcpy(dst[i..][0..16], &c);
        prev = c;
    }
}

fn xtsEncrypt(data_key: [16]u8, tweak_key: [16]u8, sector: u64, src: []const u8, dst: []u8) void {
    std.debug.assert(src.len == dst.len and src.len % 16 == 0);
    const data_ctx = std.crypto.core.aes.Aes128.initEnc(data_key);
    const tweak_ctx = std.crypto.core.aes.Aes128.initEnc(tweak_key);

    var sector_block: [16]u8 = @splat(0);
    std.mem.writeInt(u64, sector_block[0..8], sector, .little);
    var tweak: [16]u8 = undefined;
    tweak_ctx.encrypt(&tweak, &sector_block);

    var i: usize = 0;
    while (i < src.len) : (i += 16) {
        var x: [16]u8 = undefined;
        for (0..16) |b| x[b] = src[i + b] ^ tweak[b];
        var c: [16]u8 = undefined;
        data_ctx.encrypt(&c, &x);
        for (0..16) |b| dst[i + b] = c[b] ^ tweak[b];
        xtsMultiply(&tweak);
    }
}

fn xtsMultiply(t: *[16]u8) void {
    var carry: u8 = 0;
    for (0..16) |i| {
        const next: u8 = t[i] >> 7;
        t[i] = (t[i] << 1) | carry;
        carry = next;
    }
    if (carry != 0) t[0] ^= 0x87;
}

// pkg header and entry rows are big-endian; PFSC, inodes, dirents and the map are little-endian.
fn writeU32be(dst: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, dst[offset..][0..4], value, .big);
}

fn writeU64be(dst: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, dst[offset..][0..8], value, .big);
}

fn writeU16(dst: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, dst[offset..][0..2], value, .little);
}

fn writeU32(dst: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, dst[offset..][0..4], value, .little);
}

fn writeU64(dst: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, dst[offset..][0..8], value, .little);
}

/// Writes `bytes` to a scratch file the tests read back. `.zig-cache` exists in every build.
fn writePackage(arena: std.mem.Allocator, name: []const u8, options: Options) ![]u8 {
    const bytes = try build(arena, options);
    const path = try std.fmt.allocPrint(arena, ".zig-cache/{s}", .{name});
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    return path;
}

test "synthetic pkg opens and exposes the PFSC tree" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try writePackage(arena, "p2z-synthetic.pkg", .{});
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const result = try source.Source.open(io, arena, &.{path});
    const src = switch (result) {
        .ok => |s| s,
        .fail => |failure| {
            std.debug.print("synthetic pkg rejected: {t}\n", .{failure});
            return error.SyntheticPkgRejected;
        },
    };
    defer src.close();

    try std.testing.expectEqual(plan_mod.game_content_type, src.header.content_type);
    try std.testing.expectEqualStrings("CUSA00000", src.contentId()[7..16]);
    // Five paths: the root's four children plus the file inside sce_sys.
    try std.testing.expectEqual(@as(usize, 5), src.walk.entries.len);
    for ([_][]const u8{ "eboot.bin", "notes.txt", "readme.txt", "sce_sys", "sce_sys/icon0.png" }) |wanted| {
        var found = false;
        for (src.walk.entries) |entry| {
            if (std.mem.eql(u8, entry.path, wanted)) found = true;
        }
        try std.testing.expect(found);
    }

    var seen_eboot = false;
    for (src.walk.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "eboot.bin")) {
            seen_eboot = true;
            try std.testing.expectEqual(@as(u64, media.eboot.len), entry.size);
            var data: [pfs.block_size]u8 = undefined;
            const got = try src.readPfsBlock(entry.loc, &data);
            try std.testing.expectEqualStrings(media.eboot, got[0..media.eboot.len]);
        }
    }
    try std.testing.expect(seen_eboot);
}

test "synthetic pkg converts and extracts end to end" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try writePackage(arena, "p2z-synthetic-e2e.pkg", .{});
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const archive = ".zig-cache/p2z-synthetic-e2e.zar";
    const part = archive ++ ".part";
    defer std.Io.Dir.cwd().deleteFile(io, archive) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, part) catch {};

    const opened = try source.Source.open(io, arena, &.{path});
    const src = switch (opened) {
        .ok => |s| s,
        .fail => |failure| {
            std.debug.print("synthetic pkg rejected: {t}\n", .{failure});
            return error.SyntheticPkgRejected;
        },
    };
    var sources = [_]source.Source{src};
    defer sources[0].close();

    try std.testing.expect(plan_mod.preflight(.fromSource(&sources[0]), null) == null);
    const the_plan = try plan_mod.build(arena, sources[0..1]);

    var cancelled = std.atomic.Value(bool).init(false);
    const stats = try exporter.run(arena, io, sources[0..1], &the_plan, .{
        .output = archive,
        .cancel = &cancelled,
    });
    try std.testing.expectEqual(the_plan.file_count, stats.files);

    // The archive must list exactly the pfs files plus the sce_sys pkg entry.
    const file = try std.Io.Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var reader = try zar.Reader.open(io, file, arena);
    const entries = try reader.entries();
    var files: usize = 0;
    for (entries) |entry| {
        if (entry.is_file) files += 1;
    }
    // Four pfs files plus the four pkg entries the extractor writes (entry_keys, image_key,
    // entry_names, param.sfo).
    try std.testing.expectEqual(@as(usize, 8), files);

    const out_dir = ".zig-cache/p2z-synthetic-tree";
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    const extracted = try extractor.run(arena, io, sources[0..1], &the_plan, .{
        .output = out_dir,
        .cancel = &cancelled,
    });
    try std.testing.expectEqual(the_plan.file_count, extracted.files);

    const readme = try std.Io.Dir.cwd().readFileAlloc(io, out_dir ++ "/readme.txt", arena, .unlimited);
    try std.testing.expectEqualStrings(media.readme, readme);
}

test "synthetic pkg probes and merges as a patch" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base_path = try writePackage(arena, "p2z-synthetic-base.pkg", .{});
    defer std.Io.Dir.cwd().deleteFile(io, base_path) catch {};
    const update_path = try writePackage(arena, "p2z-synthetic-update.pkg", .{
        .content_flags = pkg.content_flag_first_patch,
        .app_ver = "01.02",
        .eboot_fill = 4,
    });
    defer std.Io.Dir.cwd().deleteFile(io, update_path) catch {};

    const info = try probe.run(io, arena, update_path);
    try std.testing.expectEqualStrings("Synthetic Game", info.title.?);
    try std.testing.expectEqualStrings("CUSA00000", info.title_id.?);
    try std.testing.expectEqualStrings("01.02", info.version.?);
    try std.testing.expect(info.is_patch);

    const opened_base = try source.Source.open(io, arena, &.{base_path});
    const opened_update = try source.Source.open(io, arena, &.{update_path});
    var sources = [_]source.Source{ switch (opened_base) {
        .ok => |s| s,
        .fail => return error.SyntheticPkgRejected,
    }, switch (opened_update) {
        .ok => |s| s,
        .fail => return error.SyntheticPkgRejected,
    } };
    defer for (sources) |s| s.close();

    try std.testing.expect(plan_mod.preflight(.fromSource(&sources[0]), .fromSource(&sources[1])) == null);
    const merged = try plan_mod.build(arena, &sources);
    try std.testing.expectEqual(@as(usize, 8), merged.file_count);
}
