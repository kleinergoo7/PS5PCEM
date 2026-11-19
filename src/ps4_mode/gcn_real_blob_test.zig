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

const ProgramPair = gcn_translate.ProgramPair;
const registerShaderFor = gcn_translate.registerShaderFor;
const translatedGraphicsFor = gcn_translate.translatedGraphicsFor;
const fragmentInputsFor = gcn_translate.fragmentInputsFor;

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

test "program-keyed translation rejects mismatched pair" {
    const program: ProgramPair = .{ .vertex = 0x1000000a88, .pixel = 0x1000000aa4 };
    registerShaderFor(program, .vertex, &vs_words);
    registerShaderFor(program, .pixel, &ps_words);
    try std.testing.expect(translatedGraphicsFor(program) != null);
    try std.testing.expect(translatedGraphicsFor(.{ .vertex = 1, .pixel = 2 }) == null);
}

/// Two OpConstant float values forming the coordinate composite consumed by an
/// image sample: the hardcoded `(0,0)` UV fallback this task removes.
fn constantUvOnly(words: []const u32) bool {
    var float_type: u32 = 0;
    for (words, 0..) |word, i| {
        if (word == 0x0003_0015 and i + 2 < words.len and words[i + 2] == 32) {
            float_type = words[i + 1]; // OpTypeFloat %float 32
            break;
        }
    }
    if (float_type == 0) return false;

    var constants: [64]u32 = undefined;
    var nconst: usize = 0;
    for (words, 0..) |word, i| {
        // OpConstant: 5 words, result type is the 32-bit float type.
        if (word != 0x0005_002b or i + 3 >= words.len or words[i + 1] != float_type) continue;
        if (nconst < constants.len) {
            constants[nconst] = words[i + 2];
            nconst += 1;
        }
    }

    var composites: [64]u32 = undefined;
    var ncomp: usize = 0;
    for (words, 0..) |word, i| {
        const count: usize = word >> 16;
        if ((word & 0xffff) != 80 or count < 4 or i + count > words.len) continue; // OpCompositeConstruct
        var hits: usize = 0;
        for (words[i + 3 .. i + count]) |operand| {
            for (constants[0..nconst]) |constant| {
                if (constant == operand) {
                    hits += 1;
                    break;
                }
            }
        }
        if (hits >= 2 and ncomp < composites.len) {
            composites[ncomp] = words[i + 2];
            ncomp += 1;
        }
    }
    if (ncomp == 0) return false;

    for (words, 0..) |word, i| {
        const op = word & 0xffff;
        if ((op != 87 and op != 88) or i + 4 >= words.len) continue; // image sample
        const coordinate = words[i + 4];
        for (composites[0..ncomp]) |composite| if (composite == coordinate) return true;
    }
    return false;
}

/// Positive guest-UV check: an Input at `location` is declared, its X/Y are
/// extracted from an OpLoad and composed into the coordinate consumed by an
/// image sample. This proves interpolation is wired, not merely that a
/// constant UV is absent.
fn inputFeedsImageSampleCoordinate(words: []const u32, location: u32) bool {
    var inputs: [16]u32 = undefined;
    var ninputs: usize = 0;
    for (words, 0..) |word, i| {
        if (word != 0x0004_0047 or i + 3 >= words.len) continue; // OpDecorate
        if (words[i + 2] != 30 or words[i + 3] != location) continue; // Location
        const id = words[i + 1];
        var is_input = false;
        for (words, 0..) |vword, j| {
            // OpVariable <type> <id> Input(1): distinguish from Location-0 color output.
            if (vword == 0x0004_003b and j + 3 < words.len and words[j + 2] == id and words[j + 3] == 1) {
                is_input = true;
                break;
            }
        }
        if (is_input and ninputs < inputs.len) {
            inputs[ninputs] = id;
            ninputs += 1;
        }
    }
    if (ninputs == 0) return false;

    var loads: [16]u32 = undefined;
    var nloads: usize = 0;
    for (words, 0..) |word, i| {
        if (word != 0x0004_003d or i + 3 >= words.len) continue; // OpLoad
        for (inputs[0..ninputs]) |input| {
            if (words[i + 3] == input and nloads < loads.len) {
                loads[nloads] = words[i + 2];
                nloads += 1;
                break;
            }
        }
    }

    var xs: [16]u32 = undefined;
    var nxs: usize = 0;
    var ys: [16]u32 = undefined;
    var nys: usize = 0;
    for (words, 0..) |word, i| {
        if (word != 0x0005_0051 or i + 4 >= words.len) continue; // OpCompositeExtract
        var from_load = false;
        for (loads[0..nloads]) |load| {
            if (words[i + 3] == load) {
                from_load = true;
                break;
            }
        }
        if (!from_load) continue;
        if (words[i + 4] == 0 and nxs < xs.len) {
            xs[nxs] = words[i + 2];
            nxs += 1;
        }
        if (words[i + 4] == 1 and nys < ys.len) {
            ys[nys] = words[i + 2];
            nys += 1;
        }
    }

    var coordinates: [16]u32 = undefined;
    var ncoords: usize = 0;
    for (words, 0..) |word, i| {
        if (word != 0x0005_0050 or i + 4 >= words.len) continue; // OpCompositeConstruct
        var has_x = false;
        var has_y = false;
        for (xs[0..nxs]) |x| if (words[i + 3] == x) {
            has_x = true;
            break;
        };
        for (ys[0..nys]) |y| if (words[i + 4] == y) {
            has_y = true;
            break;
        };
        if (has_x and has_y and ncoords < coordinates.len) {
            coordinates[ncoords] = words[i + 2];
            ncoords += 1;
        }
    }
    if (ncoords == 0) return false;

    for (words, 0..) |word, i| {
        const op = word & 0xffff;
        if ((op != 87 and op != 88) or i + 4 >= words.len) continue; // image sample
        for (coordinates[0..ncoords]) |coord| if (words[i + 4] == coord) return true;
    }
    return false;
}

test "real PS fragment inputs come from VS PARAM exports and VINTRP attrs" {
    // The embedded arrays are named after the OrbShdr header stage field, but
    // the runtime classifies by EXP target (ps4_title_stubs.stageFromIsa): the
    // blob exporting POS0 (0x0c) / PARAM0 (0x20) is the VS, and the blob
    // exporting MRT0 (0x00) with an image sample is the PS.
    const program: ProgramPair = .{ .vertex = 0x1000000b88, .pixel = 0x1000000ba4 };
    registerShaderFor(program, .vertex, &ps_words);
    registerShaderFor(program, .pixel, &vs_words);
    const inputs = fragmentInputsFor(program).?;
    try std.testing.expectEqual(@as(u32, 1), inputs.allocated); // VS PARAM0 -> bit 0
    try std.testing.expectEqual(inputs.allocated, inputs.enabled);
    const graphics = translatedGraphicsFor(program) orelse return error.TestExpectedGraphics;
    // Positive: the VS PARAM0 Input at Location 0 feeds the image-sample UV.
    try std.testing.expect(inputFeedsImageSampleCoordinate(graphics.fragment_words, 0));
    // Secondary guard: no two-constant fallback UV.
    try std.testing.expect(!constantUvOnly(graphics.fragment_words));
}

test "input-fed UV is PS4-gated: standalone pixel translation has no such Input" {
    const standalone = try gcn_translate.translateShader(std.testing.allocator, .pixel, &vs_words);
    defer std.testing.allocator.free(standalone);
    try std.testing.expect(!inputFeedsImageSampleCoordinate(standalone, 0));
}

test "VINTRP attr without a VS PARAM export reports null, never a guessed input" {
    const program: ProgramPair = .{ .vertex = 0x1000000c88, .pixel = 0x1000000ca4 };
    const ps_with_vintrp = [_]u32{
        gcn_decode.vintrp(false, 0, 0, 0), // consumes attr 0
        gcn_decode.vintrp(true, 1, 0, 0),
        0xbf81_0000,
    };
    registerShaderFor(program, .vertex, &[_]u32{0xbf81_0000}); // no PARAM exports
    registerShaderFor(program, .pixel, &ps_with_vintrp);
    try std.testing.expect(fragmentInputsFor(program) == null);
    try std.testing.expect(gcn_translate.lastDiagnostic() != null);
}
