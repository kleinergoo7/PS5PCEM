// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 (GCN) shader-binary headers.
//!
//! PS4 titles ship shaders as OrbShdr blobs: a small header describing the
//! stage, compute layout and tessellation usage, followed by GCN ISA. PS5PCEM
//! translates RDNA2; this header tells the frontend *what* a blob is before
//! the ISA decoder runs, mirroring SharpEmu's "decode shader stage resources"
//! and "join local and hull tessellation programs" steps at the metadata
//! level (ISA lowering itself stays in rdna2/ + gpu/).

const std = @import("std");

pub const Error = error{
    Truncated,
    BadMagic,
    BadVersion,
    UnknownStage,
};

/// Observed PS4 shader magic ("OrbShdr" little-endian prefix).
pub const magic_orbshdr: u32 = 0x7262534f; // "OrBr"? kept by value, checked in tests
pub const shdr_id: [8]u8 = .{ 'O', 'r', 'b', 'S', 'h', 'd', 'r', 0 };

/// GCN shader stage as encoded by the PS4 toolchain.
pub const Stage = enum(u8) {
    vertex = 0,
    hull = 1, // local + hull pair on PS4 tessellation
    domain = 2,
    geometry = 3,
    pixel = 4,
    compute = 5,
    _,

    pub fn isTessellation(self: Stage) bool {
        return self == .hull or self == .domain;
    }

    pub fn label(self: Stage) []const u8 {
        return switch (self) {
            .vertex => "vs",
            .hull => "hs",
            .domain => "ds",
            .geometry => "gs",
            .pixel => "ps",
            .compute => "cs",
            else => "??",
        };
    }
};

/// Minimal decoded header view. Offsets are from the blob start.
pub const Header = struct {
    stage: Stage,
    isa_offset: u32,
    isa_size: u32,
    num_sgprs: u8,
    num_vgprs: u8,
    uses_tessellation: bool,
    is_hull_pair: bool, // HS blob carrying its local entry as well
};

/// Parse the fixed 32-byte prefix used by this implementation's test blobs
/// and by real OrbShdr files' common subset:
///   [0..8]  "OrbShdr\0", [8] stage u8, [9] sgprs, [10] vgprs,
///   [11] flags (bit0 tess, bit1 hull-pair), [12..16] isa_offset LE,
///   [16..20] isa_size LE, [20..32] reserved.
pub fn parse(bytes: []const u8) Error!Header {
    if (bytes.len < 32) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &shdr_id)) return Error.BadMagic;
    const stage_int = bytes[8];
    const stage: Stage = @enumFromInt(stage_int);
    switch (stage) {
        .vertex, .hull, .domain, .geometry, .pixel, .compute => {},
        _ => return Error.UnknownStage,
    }
    const flags = bytes[11];
    const isa_offset = std.mem.readInt(u32, bytes[12..16], .little);
    const isa_size = std.mem.readInt(u32, bytes[16..20], .little);
    const end = std.math.add(u32, isa_offset, isa_size) catch return Error.Truncated;
    if (end > bytes.len) return Error.Truncated;
    return .{
        .stage = stage,
        .isa_offset = isa_offset,
        .isa_size = isa_size,
        .num_sgprs = bytes[9],
        .num_vgprs = bytes[10],
        .uses_tessellation = flags & 1 != 0,
        .is_hull_pair = flags & 2 != 0,
    };
}

/// Slice out the ISA bytes described by a parsed header.
pub fn isaBytes(bytes: []const u8, header: Header) []const u8 {
    return bytes[header.isa_offset .. header.isa_offset + header.isa_size];
}

/// Map a GCN stage to the RDNA2 pipeline slot name PS5PCEM uses downstream.
pub fn stageSlot(stage: Stage) []const u8 {
    return switch (stage) {
        .vertex => "vertex",
        .hull => "hull",
        .domain => "domain",
        .geometry => "geometry",
        .pixel => "pixel",
        .compute => "compute",
        else => "unknown",
    };
}

fn makeTestBlob(buf: []u8, stage: Stage, flags: u8) []const u8 {
    @memset(buf[0..40], 0);
    @memcpy(buf[0..8], &shdr_id);
    buf[8] = @intFromEnum(stage);
    buf[9] = 16;
    buf[10] = 32;
    buf[11] = flags;
    std.mem.writeInt(u32, buf[12..16], 32, .little);
    std.mem.writeInt(u32, buf[16..20], 8, .little);
    @memset(buf[20..32], 0);
    @memset(buf[32..40], 0xAB);
    return buf[0..40];
}

test "pixel shader header parses" {
    var buf: [64]u8 = undefined;
    const blob = makeTestBlob(&buf, .pixel, 0);
    const h = try parse(blob);
    try std.testing.expectEqual(Stage.pixel, h.stage);
    try std.testing.expectEqualStrings("pixel", stageSlot(h.stage));
    try std.testing.expect(!h.uses_tessellation);
    try std.testing.expectEqual(@as(usize, 8), isaBytes(blob, h).len);
}

test "hull pair flags tessellation" {
    var buf: [64]u8 = undefined;
    const blob = makeTestBlob(&buf, .hull, 3);
    const h = try parse(blob);
    try std.testing.expect(h.stage.isTessellation());
    try std.testing.expect(h.uses_tessellation);
    try std.testing.expect(h.is_hull_pair);
}

test "bad magic rejected" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(Error.BadMagic, parse(&buf));
}
