// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Focused PS4 graphics behavior test driven by Terraria's real captured DCB.
//!
//! The fixture is the exact 3160 bytes / 790 dwords captured from Terraria's
//! PS4 setup DCB (source: /tmp/opencode/terraria-dcb.bin). It is embedded so
//! the test is hermetic: no game run, no guest memory, no GPU backend needed.
//!
//! This drives the same PS4-only path used by
//! `sceGnmSubmitAndFlipCommandBuffers` (src/hle/libs/gnm_compat.zig):
//!   colorTargetAddress -> synthesizeRenderTargetRegs ->
//!   synthesizeShaderProgramRegs -> sanitize
//! and asserts what the GAME actually provides: its colour-target address,
//! its recovered draw/dispatch packets, and the shader addresses recorded by
//! sceGnmSet{Ps,Vs}Shader.

const std = @import("std");
const pm4 = @import("pm4_sanitize.zig");
const shader_binding = @import("shader_binding.zig");

/// Terraria PS4 setup DCB, 790 dwords, verbatim from the capture.
const captured_dcb = [_]u32{
    0xc0055800, 0x88c40000, 0x00000001, 0x00000000, 0x00000000, 0x00000000, 0x0000000a, 0xc0016900,
    0x00000205, 0x00000246, 0xc0016900, 0x000002df, 0x00000000, 0xc0016900, 0xc0066900, 0x00000318,
    0x10100a00, 0x09f0009f, 0x00003bff, 0x00000000, 0x00028828, 0x0000014a, 0xc0046900, 0x0000031f,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xc0001000, 0x02d00500, 0xc0016900, 0x00000010,
    0x00000000, 0xc0016900, 0x00000011, 0x00000000, 0xc0016900, 0x00000205, 0x00000246, 0xc0016900,
    0x000002df, 0x00000000, 0xc0016900, 0x00000204, 0x00080000, 0xc0016900, 0x000001e0, 0x00000000,
    0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e1, 0x00000000, 0xc0016900, 0x000002dc,
    0x0000aa00, 0xc0016900, 0x000001e2, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900,
    0x000001e3, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e4, 0x00000000,
    0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e5, 0x00000000, 0xc0016900, 0x000002dc,
    0x0000aa00, 0xc0016900, 0x000001e6, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900,
    0x000001e7, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x0000008e, 0x000000ff,
    0xc0046900, 0x00000105, 0x3f800000, 0x3f800000, 0x3f800000, 0x3f800000, 0xc0016900, 0x00000200,
    0x00000016, 0xc0016900, 0x0000010b, 0x00000000, 0xc0026900, 0x0000010c, 0x00000000, 0x00000000,
    0xc0026900, 0x000000b4, 0x00000000, 0x3f800000, 0xc0066900, 0x0000010f, 0x44200000, 0x44200000,
    0xc3b40000, 0x43b40000, 0x00000000, 0x00000000, 0xc0016900, 0x00000206, 0x0000043f, 0xc0026900,
    0x0000000c, 0x00000000, 0x02d00500, 0xc0016900, 0x0000008d, 0x00140028, 0xc0016900, 0x000002fa,
    0x42b40000, 0xc0016900, 0x000002fc, 0x4248cccb, 0xc0016900, 0x000002fb, 0x3f800000, 0xc0016900,
    0x000002fd, 0x3f800000, 0xc0016900, 0x00000205, 0x00000244, 0xc0016900, 0x000002df, 0x00000000,
    0xc0016900, 0x00000204, 0x00080000, 0xc0026900, 0x000000b4, 0x00000000, 0x3f800000, 0xc0066900,
    0x0000010f, 0x44700000, 0x44700000, 0xc4200000, 0x44200000, 0x00000000, 0x3f800000, 0xc0016900,
    0x00000206, 0x0000043f, 0xc0026900, 0x0000000c, 0x00000000, 0x05000780, 0xc0016900, 0x0000008d,
    0x0028003c, 0xc0016900, 0x000002fa, 0x4248cccb, 0xc0016900, 0x000002fc, 0x42048887, 0xc0016900,
    0x000002fb, 0x3f800000, 0xc0016900, 0x000002fd, 0x3f800000, 0xc0066900, 0x00000318, 0x10168c80,
    0x0ef000ef, 0x00007f7f, 0x00000000, 0x00028028, 0x0000014a, 0xc0046900, 0x0000031f, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0xc0001000, 0x04380780, 0xc0016900, 0x00000010, 0x00000000,
    0xc0016900, 0x00000011, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xc0041000, 0x68752000, 0xff000000, 0x00000000,
    0x00000000, 0x00000000, 0xc0047602, 0x00000248, 0x168c8000, 0x00047010, 0x001fe000, 0x18024004,
    0xc0047602, 0x00000244, 0x00000704, 0x00040010, 0x00000001, 0x20024004, 0xc0021000, 0x68752000,
    0x001fe000, 0x00000000, 0xc0047602, 0x0000024c, 0x0000074c, 0x00100010, 0x00000001, 0x20077fac,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xc0055000, 0x60000000, 0x10000900, 0x00000010, 0x0003022c, 0x00000000, 0x2820007c,
    0xc0031502, 0x00007f80, 0x00000001, 0x00000001, 0x00000001, 0xc0001000, 0x00000000, 0xc0021000,
    0x68753000, 0x00000000, 0x00000000, 0xc0034802, 0x0000062f, 0x00000810, 0x40000010, 0x00000001,
    0xc0053c00, 0x00000013, 0x00000810, 0x00000010, 0x00000001, 0xffffffff, 0x0000000a, 0xc0055800,
    0x80c40000, 0x00000001, 0x00000000, 0x00000000, 0x00000000, 0x0000000a, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xc0026900, 0x000000b4, 0x00000000, 0x3f800000,
    0xc0066900, 0x0000010f, 0x44700000, 0x44700000, 0xc4200000, 0x44200000, 0x00000000, 0x3f800000,
    0xc0016900, 0x00000206, 0x0000043f, 0xc0026900, 0x0000000c, 0x00000000, 0x05000780, 0xc0016900,
    0x0000008d, 0x0028003c, 0xc0016900, 0x000002fa, 0x4248cccb, 0xc0016900, 0x000002fc, 0x42048887,
    0xc0016900, 0x000002fb, 0x3f800000, 0xc0016900, 0x000002fd, 0x3f800000, 0xc0016900, 0x000001e0,
    0x40000501, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e1, 0x40000501, 0xc0016900,
    0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e2, 0x40000501, 0xc0016900, 0x000002dc, 0x0000aa00,
    0xc0016900, 0x000001e3, 0x40000501, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e4,
    0x40000501, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e5, 0x40000501, 0xc0016900,
    0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e6, 0x40000501, 0xc0016900, 0x000002dc, 0x0000aa00,
    0xc0016900, 0x000001e7, 0x40000501, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x0000008e,
    0x000000ff, 0xc0046900, 0x00000105, 0x3f800000, 0x3f800000, 0x3f800000, 0x3f800000, 0xc0016900,
    0x00000200, 0x00000010, 0xc0016900, 0x0000010b, 0x00000000, 0xc0026900, 0x0000010c, 0x00000000,
    0x00000000, 0xc0016900, 0x000002d5, 0x00000000, 0xc0047600, 0x00000054, 0x1009cb60, 0x00100010,
    0x00000004, 0x20077fac, 0xc0047600, 0x00000018, 0x00000092, 0x00fff000, 0x09500000, 0x00000000,
    0xc0087600, 0x00000010, 0x10170c00, 0x00a00000, 0x0077c2ab, 0x94d00f2e, 0x0055e000, 0x00000000,
    0x00000000, 0x00000000, 0xc0017900, 0x00000242, 0x00000013, 0xc0002a00, 0x00000001, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xc0055000, 0x60000000, 0x1009ce00, 0x00000010,
    0x0003022c, 0x00000000, 0x282000c4, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0xc0055000, 0x60000000, 0x1009d000, 0x00000010, 0x0003022c,
    0x00000000, 0x282000a4, 0xc0027600, 0x0000004c, 0x1009cbb0, 0x00000010, 0xc0027600, 0x0000004e,
    0x10000f5c, 0x00000010, 0xc0026900, 0x00000191, 0x00000000, 0x00000001, 0xc0012d00, 0x00000004,
    0x00000002, 0xc0001000, 0x00000000, 0xc0055800, 0x82c40040, 0x00007f80, 0x00000000, 0x10168c80,
    0x00000000, 0x0000000a, 0xc0026900, 0x000000b4, 0x00000000, 0x3f800000, 0xc0066900, 0x0000010f,
    0x44200000, 0x44200000, 0xc3b40000, 0x43b40000, 0x00000000, 0x3f800000, 0xc0016900, 0x00000206,
    0x0000043f, 0xc0026900, 0x0000000c, 0x00000000, 0x02d00500, 0xc0016900, 0x0000008d, 0x00140028,
    0xc0016900, 0x000002fa, 0x42b40000, 0xc0016900, 0x000002fc, 0x4248cccb, 0xc0016900, 0x000002fb,
    0x3f800000, 0xc0016900, 0x000002fd, 0x3f800000, 0xc0066900, 0x00000318, 0x10100a00, 0x09f0009f,
    0x00003bff, 0x00000000, 0x00028828, 0x0000014a, 0xc0046900, 0x0000031f, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xc0001000, 0x02d00500, 0xc0016900, 0x00000010, 0x00000000, 0xc0016900,
    0x00000011, 0x00000000, 0xc0016900, 0x000001e0, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00,
    0xc0016900, 0x000001e1, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e2,
    0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e3, 0x00000000, 0xc0016900,
    0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e4, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00,
    0xc0016900, 0x000001e5, 0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e6,
    0x00000000, 0xc0016900, 0x000002dc, 0x0000aa00, 0xc0016900, 0x000001e7, 0x00000000, 0xc0016900,
    0x000002dc, 0x0000aa00, 0xc0016900, 0x0000008e, 0x000000ff, 0xc0046900, 0x00000105, 0x3f800000,
    0x3f800000, 0x3f800000, 0x3f800000, 0xc0016900, 0x000002d5, 0x00000000, 0xc0047600, 0x00000054,
    0x1009d0a4, 0x00100010, 0x00000004, 0x20077fac, 0xc0047600, 0x00000018, 0x00000092, 0x00fff000,
    0x09500000, 0x00000000, 0xc0087600, 0x00000010, 0x10168c80, 0x00a00000, 0x010dc77f, 0x94a00fac,
    0x00efe000, 0x00000000, 0x00000000, 0x00000000, 0xc0017900, 0x00000242, 0x00000013, 0xc0002a00,
    0x00000001, 0xc0027600, 0x0000004c, 0x1009cbb0, 0x00000010, 0xc0027600, 0x0000004e, 0x10000f8c,
    0x00000010, 0xc0012d00, 0x00000004, 0x00000002, 0xc0001000, 0x00000000, 0xc03e1000, 0x68750777,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
};

/// PM4 Type-3 header used for the expected synthesized packets.
fn command(opcode: u8, body_words: usize) u32 {
    return (@as(u32, 3) << 30) |
        (@as(u32, @intCast(body_words - 1)) << 16) |
        (@as(u32, opcode) << 8);
}

fn packetOpcode(header: u32) u8 {
    return @as(u8, @truncate(header >> 8));
}

fn packetBodyLen(header: u32) usize {
    return @as(usize, @intCast((header >> 16) & 0x3fff)) + 1;
}

test "Terraria DCB: guest colour target, draws and shader programs survive the PS4 path" {
    // Simulate sceGnmSet{Ps,Vs}Shader recorded at the HLE boundary.
    shader_binding.reset();
    defer shader_binding.reset();
    const ps_addr: u64 = 0xab12_3456_0000;
    const vs_addr: u64 = 0x789a_bc00;
    shader_binding.setPixelShader(ps_addr);
    shader_binding.setVertexShader(vs_addr);

    // Sanity: this is the real capture, not a trimmed or re-derived fixture.
    try std.testing.expectEqual(@as(usize, 790), captured_dcb.len);
    try std.testing.expectEqual(@as(u32, 0xc005_5800), captured_dcb[0]);

    // (a) The guest colour-target base the GAME writes (CB_COLOR0_BASE at
    // word 14) is recovered as a 40-bit GPU address.
    const cb_base = pm4.colorTargetAddress(&captured_dcb);
    try std.testing.expect(cb_base != null);
    try std.testing.expectEqual(@as(u64, 0x0010_100a_0000), cb_base.?);

    // Rebuild the exact stream handed to agc_submit.submitDeviceStream.
    var clean: [captured_dcb.len + pm4.max_synthesized_dwords + pm4.max_shader_reg_dwords]u32 = undefined;
    const rt_words = pm4.synthesizeRenderTargetRegs(&captured_dcb, &clean, .{});
    try std.testing.expectEqual(@as(usize, 9), rt_words); // one CB slot present

    // The synthesized render-target registers describe the guest target.
    const dims = pm4.Dimensions{};
    const expected_dim = ((dims.width - 1) << 14) | (dims.height - 1);
    try std.testing.expectEqual(command(0x69, 2), clean[0]); // BASE_HIGH 0x390
    try std.testing.expectEqual(@as(u32, 0x390), clean[1]);
    try std.testing.expectEqual(@as(u32, 0), clean[2]);
    try std.testing.expectEqual(@as(u32, 0x3b0), clean[4]); // DIM
    try std.testing.expectEqual(expected_dim, clean[5]);
    try std.testing.expectEqual(@as(u32, 0x3b8), clean[7]); // DEPTH/TILE
    try std.testing.expectEqual(@as(u32, 0), clean[8]);

    // (c) The shader addresses recorded by sceGnmSet{Ps,Vs}Shader are injected
    // as PS (0x008) and VS (0x048) SH program-address registers.
    const sh_words = pm4.synthesizeShaderProgramRegs(shader_binding.programs(), clean[rt_words..]);
    try std.testing.expectEqual(@as(usize, 8), sh_words);
    const sh = rt_words;
    try std.testing.expectEqual(command(0x76, 3), clean[sh + 0]);
    try std.testing.expectEqual(@as(u32, 0x008), clean[sh + 1]);
    try std.testing.expectEqual(@as(u32, @truncate(ps_addr >> 8)), clean[sh + 2]);
    try std.testing.expectEqual(@as(u32, @as(u32, @truncate(ps_addr >> 40)) & 0xff), clean[sh + 3]);
    try std.testing.expectEqual(command(0x76, 3), clean[sh + 4]);
    try std.testing.expectEqual(@as(u32, 0x048), clean[sh + 5]);
    try std.testing.expectEqual(@as(u32, @truncate(vs_addr >> 8)), clean[sh + 6]);
    try std.testing.expectEqual(@as(u32, @as(u32, @truncate(vs_addr >> 40)) & 0xff), clean[sh + 7]);

    const prefix_words = rt_words + sh_words;
    var stats: pm4.Stats = .{};
    const body_words = pm4.sanitize(&captured_dcb, clean[prefix_words..], &stats);
    try std.testing.expectEqual(@as(usize, 664), body_words);
    try std.testing.expectEqual(@as(usize, 157), stats.kept);
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_context);

    // (b) The recovered stream keeps the GAME's real work: one DISPATCH_DIRECT
    // and both DRAW_INDEX_AUTO packets, with their original bodies intact.
    const stream = clean[prefix_words .. prefix_words + body_words];
    var dispatch_count: usize = 0;
    var auto_draw_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < stream.len) {
        const header = stream[cursor];
        try std.testing.expectEqual(@as(u2, 3), @as(u2, @truncate(header >> 30)));
        const body_len = packetBodyLen(header);
        try std.testing.expect(cursor + 1 + body_len <= stream.len);
        switch (packetOpcode(header)) {
            0x15 => { // DISPATCH_DIRECT
                dispatch_count += 1;
                try std.testing.expectEqual(@as(usize, 4), body_len);
                try std.testing.expectEqual(@as(u32, 0x7f80), stream[cursor + 1]);
            },
            0x2d => { // DRAW_INDEX_AUTO
                auto_draw_count += 1;
                try std.testing.expectEqual(@as(usize, 2), body_len);
                try std.testing.expectEqual(@as(u32, 4), stream[cursor + 1]);
                try std.testing.expectEqual(@as(u32, 2), stream[cursor + 2]);
            },
            else => {},
        }
        cursor += 1 + body_len;
    }
    try std.testing.expectEqual(@as(usize, 1), dispatch_count);
    try std.testing.expectEqual(@as(usize, 2), auto_draw_count);
    try std.testing.expectEqual(stream.len, cursor);
}

// ---------------------------------------------------------------------------
// NEGATIVE capability marker — documents what the shared backend cannot yet do.
// ---------------------------------------------------------------------------
test "NEGATIVE (missing capability): GCN shader words are not translated to SPIR-V; PS4 replay uses the probe fallback" {
    // shortcut: the shared backend cannot consume GCN ISA. The PS4 submit path
    // records only the sceGnmSet{Ps,Vs}Shader *addresses* and injects SH
    // program-address registers; src/vulkan/backend.zig then replays the
    // fixed-color probe shader (drawPs4FixedColor). The desired behavior is
    // "guest GCN shader words are translated into real SPIR-V and bound".
    // Replace the probe with a real GCN->SPIR-V translator bound from the PS4
    // submit boundary, then assert the translated module is present here.
    shader_binding.reset();
    defer shader_binding.reset();
    shader_binding.setPixelShader(ps_addr_for_negative);
    shader_binding.setVertexShader(vs_addr_for_negative);
    const programs = shader_binding.programs();
    try std.testing.expect(programs.pixel != 0 and programs.vertex != 0);

    var out: [pm4.max_shader_reg_dwords]u32 = undefined;
    const n = pm4.synthesizeShaderProgramRegs(programs, &out);
    // Today: only the two PS/VS program-address registers are bound — there
    // are no translated SPIR-V words or shader module in this path.
    try std.testing.expectEqual(@as(usize, pm4.max_shader_reg_dwords), n);
    // Desired (RED once implemented): translated SPIR-V words are also bound.
    // try std.testing.expect(n > @as(usize, pm4.max_shader_reg_dwords));
}

const ps_addr_for_negative: u64 = 0xab12_3456_0000;
const vs_addr_for_negative: u64 = 0x789a_bc00;
