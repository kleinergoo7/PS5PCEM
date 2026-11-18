// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Key unwrap for encrypted pkgs: pkg derived key 3, ivKey, ekpfs, and the PFS data/tweak
//! keys. Ported from shadPS4 pkg.cpp (GPL-2.0-or-later).

const std = @import("std");
const crypto = @import("crypto.zig");
const pkg = @import("pkg.zig");
const pieces = @import("pieces.zig");

pub const Error = error{
    MissingEntryKeys,
    MissingImageKey,
    EntryKeysOutOfRange,
    ImageKeyOutOfRange,
    SeedOutOfRange,
    Dk3UnwrapFailed,
    EkpfsUnwrapFailed,
    UnexpectedEndOfFile,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.MissingEntryKeys => "pkg has no entry 0x10 (entry keys)",
        error.MissingImageKey => "pkg has no entry 0x20 (image key)",
        error.EntryKeysOutOfRange => "entry 0x10 points outside the file",
        error.ImageKeyOutOfRange => "entry 0x20 points outside the file",
        error.SeedOutOfRange => "PFS seed at image offset 0x370 is outside the file",
        error.Dk3UnwrapFailed => "pkg derived key 3 failed to unwrap",
        error.EkpfsUnwrapFailed => "ekpfs failed to unwrap",
        error.UnexpectedEndOfFile => "file ended while reading key material",
    };
}

pub const Keys = struct {
    data: [16]u8,
    tweak: [16]u8,
    /// pkg derived key 3, needed to decrypt the sce_sys NP entries (0x400-0x403).
    dk3: [32]u8,
};

/// Reads key material through the piece-aware stream, checking every range against the size.
pub fn derive(
    stream: pieces.Stream,
    file_size: u64,
    header: pkg.Header,
    entries: []const pkg.Entry,
) Error!Keys {
    const read_at = struct {
        fn call(s: pieces.Stream, offset: u64, buf: []u8) Error!void {
            s.readExact(s.io, offset, buf) catch return error.UnexpectedEndOfFile;
        }
    }.call;
    const entry_keys = findEntry(entries, pkg.entry_id_entry_keys) orelse return error.MissingEntryKeys;
    const image_key = findEntry(entries, pkg.entry_id_image_key) orelse return error.MissingImageKey;

    if (!withinFile(entry_keys.offset, 0x800, file_size)) return error.EntryKeysOutOfRange;
    var keyset: [0x800]u8 = undefined;
    try read_at(stream, entry_keys.offset, &keyset);

    // Layout inside entry 0x10: 32-byte seed digest, seven 32-byte digests, seven 256-byte
    // RSA blobs. The pkg derived key 3 is blob 3.
    const dk3_blob = keyset[256 + 3 * 256 ..][0..256];
    var dk3_buf: [32]u8 = undefined;
    const dk3 = crypto.rsaPkcs1v15Decrypt(crypto.pkg_key_set, dk3_blob, &dk3_buf) catch
        return error.Dk3UnwrapFailed;
    if (dk3.len != 32) return error.Dk3UnwrapFailed;

    if (!withinFile(image_key.offset, 256, file_size)) return error.ImageKeyOutOfRange;
    var imgkey_cipher: [256]u8 = undefined;
    try read_at(stream, image_key.offset, &imgkey_cipher);

    const entry_bytes = entryRawBytes(image_key);
    var hashed: [64]u8 = undefined;
    @memcpy(hashed[0..32], &entry_bytes);
    @memcpy(hashed[32..], dk3);
    const iv_key = crypto.sha256(&hashed);

    var img_key: [256]u8 = undefined;
    crypto.aesCbcDecrypt(iv_key[16..32].*, iv_key[0..16].*, &imgkey_cipher, &img_key);

    var ekpfs_buf: [32]u8 = undefined;
    const ekpfs = crypto.rsaPkcs1v15Decrypt(crypto.fake_key_set, &img_key, &ekpfs_buf) catch
        return error.EkpfsUnwrapFailed;
    if (ekpfs.len != 32) return error.EkpfsUnwrapFailed;

    var seed: [16]u8 = undefined;
    const seed_offset = header.pfs_image_offset + 0x370;
    if (!withinFile(seed_offset, seed.len, file_size)) return error.SeedOutOfRange;
    try read_at(stream, seed_offset, &seed);

    var input: [20]u8 = undefined;
    std.mem.writeInt(u32, input[0..4], 1, .little);
    @memcpy(input[4..], &seed);
    const digest = crypto.hmacSha256(ekpfs, &input);

    return .{
        .tweak = digest[0..16].*,
        .data = digest[16..32].*,
        .dk3 = dk3[0..32].*,
    };
}

fn findEntry(entries: []const pkg.Entry, id: u32) ?pkg.Entry {
    for (entries) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

/// The raw 32 bytes of the entry table row, in on-disk field order.
fn entryRawBytes(entry: pkg.Entry) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], entry.id, .big);
    std.mem.writeInt(u32, out[4..8], entry.filename_offset, .big);
    std.mem.writeInt(u32, out[8..12], entry.flags1, .big);
    std.mem.writeInt(u32, out[12..16], entry.flags2, .big);
    std.mem.writeInt(u32, out[16..20], entry.offset, .big);
    std.mem.writeInt(u32, out[20..24], entry.size, .big);
    @memset(out[24..32], 0);
    return out;
}

fn withinFile(offset: u64, len: usize, file_size: u64) bool {
    const end = std.math.add(u64, offset, len) catch return false;
    return end <= file_size;
}
