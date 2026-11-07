// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Per-title patch table for PS4 mode.
//!
//! Mirrors SharpEmu's GNM patch support: small verified in-memory patches
//! keyed by TITLE_ID, applied at load. Entries are pure data (address,
//! expected bytes, replacement) so the loader can verify-then-write without
//! trusting the table blindly.

const std = @import("std");

pub const Patch = struct {
    offset: u64, // file offset inside eboot.bin
    expected: []const u8, // bytes that must be present
    replacement: []const u8, // same length as expected
};

pub const TitlePatches = struct {
    title_id: []const u8,
    description: []const u8,
    patches: []const Patch,
};

pub const table = [_]TitlePatches{
    // Reserved examples; the refining AI adds verified entries here.
};

/// Look up patches for a title id. Returns null when no patches exist.
pub fn lookup(title_id: []const u8) ?TitlePatches {
    for (table) |t| {
        if (std.mem.eql(u8, t.title_id, title_id)) return t;
    }
    return null;
}

pub const ApplyError = error{
    Truncated,
    Mismatch,
    LengthMismatch,
};

/// Verify-then-write every patch into `image`. Fails without writing when any
/// expectation mismatches (caller decides whether that is fatal).
pub fn apply(title: TitlePatches, image: []u8) ApplyError!u32 {
    var applied: u32 = 0;
    for (title.patches) |p| {
        if (p.expected.len != p.replacement.len) return ApplyError.LengthMismatch;
        const end = p.offset + p.expected.len;
        if (end > image.len) return ApplyError.Truncated;
        const off: usize = @intCast(p.offset);
        if (!std.mem.eql(u8, image[off..][0..p.expected.len], p.expected)) return ApplyError.Mismatch;
        @memcpy(image[off..][0..p.replacement.len], p.replacement);
        applied += 1;
    }
    return applied;
}
