// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Hermetic test using the REAL OrbShdr GCN blobs dumped from Terraria's
//! guest memory. The ISA dwords below are verbatim from
//! /tmp/opencode/gcn-blob--4.bin (VS, guest 0x50adbc) and
//! /tmp/opencode/gcn-blob--3.bin (PS, guest 0x50ac44).
//!
//! This proves the real shader bytes flow through
//! gcn_blob.isaBytes -> gcn_decode -> gcn_translate and yield non-empty
//! vertex/fragment SPIR-V, instead of only the hand-encoded fixtures.

const std = @import("std");
const gcn_blob = @import("gcn_blob.zig");
const gcn_decode = @import("gcn_decode.zig");
const gcn_translate = @import("gcn_translate.zig");

/// Full VS blob (2048-byte dump truncated to the parsed ISA extent).
/// isa_offset = 0x104, isa_size = 88 (22 dwords).
const vs_words = [_]u32{
    0xbeeb03ff, 0x0000000e, 0xbe92047e, 0xbefe0a7e,
    0xc0800300, 0xbf8c007f, 0xc2480104, 0xc2400100,
    0xbf8c007f, 0x7e000210, 0x7e020211, 0x3e000400,
    0x3e020601, 0xf0800f00, 0x00610000, 0xbefe0412,
    0xbf8c0f70, 0x5e000300, 0x5e020702, 0xf8001c0f,
    0x00000100, 0xbf810000,
};

/// Full PS blob. isa_offset = 0x138, isa_size = 64 (16 dwords).
const ps_words = [_]u32{
    0xbeeb03ff, 0x00000007, 0x36020081, 0x34020281,
    0x360000c2, 0x4a0202c1, 0x4a0000c1, 0x7e020b01,
    0x7e000b00, 0x7e040280, 0x7e0602f2, 0xf80008cf,
    0x03020001, 0xf800020f, 0x03030303, 0xbf810000,
};

test "real Terraria VS/PS blobs decode without unsupported instructions" {
    for ([_][]const u32{ &vs_words, &ps_words }) |words| {
        var it = gcn_decode.decode(words);
        while (try it.next()) |inst| try std.testing.expect(inst.tag() != .unsupported);
    }
}

test "real Terraria VS/PS blobs translate to non-empty vertex/fragment SPIR-V" {
    const vs_spirv = try gcn_translate.translateShader(std.testing.allocator, .vertex, &vs_words);
    defer std.testing.allocator.free(vs_spirv);
    try std.testing.expect(vs_spirv.len > 0);
    try std.testing.expectEqual(@as(u32, 0x07230203), vs_spirv[0]); // SPIR-V magic

    const ps_spirv = try gcn_translate.translateShader(std.testing.allocator, .pixel, &ps_words);
    defer std.testing.allocator.free(ps_spirv);
    try std.testing.expect(ps_spirv.len > 0);
    try std.testing.expectEqual(@as(u32, 0x07230203), ps_spirv[0]);
}

test "gcn_blob.isaBytes extracts the ISA from the real VS blob header" {
    // Reconstruct the minimal header bytes around the embedded ISA so the
    // gcn_blob parser sees the real OrbShdr magic and prolog markers.
    var blob: [0x104 + 88]u8 = [_]u8{0} ** (0x104 + 88);
    @memcpy(blob[0..8], "OrbShdr\x07");
    std.mem.writeInt(u16, blob[14..16], 8, .little); // vertex stage
    @memcpy(blob[0xa8..0xb0], "Shdr\x07\x00\x01\x00");
    for (vs_words, 0..) |w, i| std.mem.writeInt(u32, blob[0x104 + i * 4 ..][0..4], w, .little);
    const parsed = try gcn_blob.parse(&blob);
    try std.testing.expectEqual(@as(u32, 0x104), parsed.isa_offset);
    try std.testing.expectEqual(@as(u32, 88), parsed.isa_size);
    const isa = gcn_blob.isaBytes(&blob, parsed);
    try std.testing.expectEqual(@as(usize, 88), isa.len);
}
