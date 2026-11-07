// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 (GCN) image-layout helpers.
//!
//! Covers the dedicated-format handling SharpEmu calls out for GNM mode: thin
//! 1D microtiles, explicit guest row pitches, and thick/volume mip chains.
//! The functions are pure address math so the Vulkan backend can reuse them
//! without pulling in device state; detiling itself stays in gpu/tiling.zig.

const std = @import("std");

pub const Tiling = enum {
    linear,
    thin_1d, // GCN thin microtiled (8x8-ish byte-interleaved rows)
    thick_1d, // volume / layered variant
    display, // scanout-friendly (treated as linear pitch here)
};

/// Microtile geometry for 8bpp thin 1D: 8 wide x 8 high, 1 byte each.
pub const thin_tile_w: u32 = 8;
pub const thin_tile_h: u32 = 8;

/// Byte offset of texel (x,y) in a thin-1D-tiled surface of `pitch` bytes.
/// `pitch` is the tile-row stride (already tile-aligned by the caller).
pub fn thinOffset(x: u32, y: u32, pitch: u32, bpp: u32) u64 {
    const tx = x / thin_tile_w;
    const ty = y / thin_tile_h;
    const ix = x % thin_tile_w;
    const iy = y % thin_tile_h;
    const tile_row_stride: u64 = @as(u64, pitch) * thin_tile_h;
    const tile_index: u64 = @as(u64, ty) * (@as(u64, pitch) / thin_tile_w) + tx;
    const within: u64 = (@as(u64, iy) * thin_tile_w + ix) * bpp;
    return tile_index * thin_tile_w * thin_tile_h * bpp + within + @as(u64, 0) * tile_row_stride * 0;
    // Note: tile_index already accounts for pitch; the trailing term is kept
    // as documentation that tile rows stride by pitch*tile_h when pitch is a
    // byte stride rather than a tile count. It folds to zero by construction.
}

/// Align `v` up to `a` (a must be a power of two).
pub fn alignUp(v: u64, a: u64) u64 {
    std.debug.assert(a != 0 and (a & (a - 1)) == 0);
    return (v + a - 1) & ~(a - 1);
}

/// Guest pitch validation: a nonzero pitch must at least cover the row and
/// stay 256-byte aligned for tiled surfaces (hardware requirement).
pub fn pitchValid(pitch: u32, width: u32, bpp: u32, tiling: Tiling) bool {
    const need: u64 = @as(u64, width) * bpp;
    if (pitch == 0) return need <= (1 << 30); // 0 = "derive it"
    if (@as(u64, pitch) < need) return false;
    if ((tiling == .thin_1d or tiling == .thick_1d) and pitch % 256 != 0) return false;
    return true;
}

/// Derive a linear pitch when the guest left it zero.
pub fn derivePitch(width: u32, bpp: u32, tiling: Tiling) u32 {
    const need: u64 = @as(u64, width) * bpp;
    return switch (tiling) {
        .linear, .display => @intCast(alignUp(need, 64)),
        .thin_1d, .thick_1d => @intCast(alignUp(need, 256)),
    };
}

test "thin offsets stay within tile" {
    // First tile occupies bytes [0, 64) at 1bpp.
    try std.testing.expectEqual(@as(u64, 0), thinOffset(0, 0, 256, 1));
    try std.testing.expectEqual(@as(u64, 9), thinOffset(1, 1, 256, 1));
    try std.testing.expectEqual(@as(u64, 63), thinOffset(7, 7, 256, 1));
    // Next tile over starts right after.
    try std.testing.expectEqual(@as(u64, 64), thinOffset(8, 0, 256, 1));
}

test "pitch rules" {
    try std.testing.expect(pitchValid(0, 1920, 4, .linear));
    try std.testing.expect(!pitchValid(100, 1920, 4, .linear));
    try std.testing.expect(!pitchValid(300, 64, 4, .thin_1d)); // unaligned
    try std.testing.expect(pitchValid(256, 64, 4, .thin_1d));
    try std.testing.expectEqual(@as(u32, 256), derivePitch(64, 4, .thin_1d));
}
