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
const gcn_resources = @import("gcn_resources.zig");

const ProgramPair = gcn_translate.ProgramPair;
const registerShaderFor = gcn_translate.registerShaderFor;
const translatedGraphicsFor = gcn_translate.translatedGraphicsFor;
const fragmentInputsFor = gcn_translate.fragmentInputsFor;
const vertexDataSourceFor = gcn_translate.vertexDataSourceFor;
const capture = gcn_resources.capture;
const real_terraria_dcb = @import("terraria_frame_test.zig").captured_dcb;

/// Pair used by the PS4 vertex-path check. `vs_words` is registered as VS (the
/// writer maps EXP target 0 to BuiltIn Position) and `ps_words` as PS.
const program: ProgramPair = .{ .vertex = 0x1000000a88, .pixel = 0x1000000aa4 };

/// True when the synthetic `VertexIndex & 1 / >> 1` -> float quad-corner pattern
/// (seeded by the rdna2 writer's vertex_corner_vgprs option) is present.
fn syntheticCornerSequence(words: []const u32) bool {
    var masked: [256]u32 = undefined;
    var nmasked: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const wc: usize = words[i] >> 16;
        const op: u32 = words[i] & 0xffff;
        if (wc >= 5 and i + wc <= words.len) {
            // OpBitwiseAnd(199) by 1/2 or OpShiftRightLogical(194) by 1: the
            // constants the quad-corner seed uses, unlike descriptor masks.
            const amount = words[i + 4];
            const corner_op = (op == 199 and (amount == 1 or amount == 2)) or (op == 194 and amount == 1);
            if (corner_op and nmasked < masked.len) {
                masked[nmasked] = words[i + 2]; // result id of the mask/shift
                nmasked += 1;
            }
        }
        i += @max(wc, 1);
    }
    if (nmasked == 0) return false;
    i = 5;
    while (i < words.len) {
        const wc: usize = words[i] >> 16;
        if (wc >= 4 and i + wc <= words.len and (words[i] & 0xffff) == 124) { // OpBitcast
            for (masked[0..nmasked]) |id| if (words[i + 3] == id) return true;
        }
        i += @max(wc, 1);
    }
    return false;
}

fn tracesToStorageLoad(start: u32, producers: []const ?[4]u32, sb_load: []const bool, depth: usize) bool {
    if (start >= producers.len) return false;
    if (sb_load[start]) return true;
    if (depth > 24) return false;
    if (producers[start]) |ops| {
        for (ops) |op| {
            if (op != 0 and tracesToStorageLoad(op, producers, sb_load, depth + 1)) return true;
        }
    }
    return false;
}

/// The POS0 store may be wrapped in an OpSelect for the exec mask. Walk back
/// to the OpCompositeConstruct it feeds and check that construct's components.
fn positionCompositeTracesToStorageLoad(start: u32, producers: []const ?[4]u32, is_composite: []const bool, sb_load: []const bool, depth: usize) bool {
    if (start >= producers.len or depth > 24) return false;
    if (is_composite[start]) {
        if (producers[start]) |components| {
            for (components) |component| {
                if (component != 0 and tracesToStorageLoad(component, producers, sb_load, 0)) return true;
            }
        }
    }
    if (producers[start]) |ops| {
        for (ops) |op| {
            if (op != 0 and positionCompositeTracesToStorageLoad(op, producers, is_composite, sb_load, depth + 1)) return true;
        }
    }
    return false;
}

/// True when the value stored to BuiltIn Position traces back through SSA
/// producers to an OpLoad of a storage-buffer-backed pointer — i.e. guest
/// vertex bytes staged into the storage buffer feed POS0, not a synthesized
/// corner or a host constant.
fn positionTracesToStorageBufferLoad(words: []const u32) bool {
    const max_id = 1024;
    var sb_var: [max_id]bool = @splat(false);
    var sb_ptr: [max_id]bool = @splat(false);
    var sb_load: [max_id]bool = @splat(false);
    var is_composite: [max_id]bool = @splat(false);
    var producers: [max_id]?[4]u32 = @splat(null);

    var i: usize = 5;
    while (i < words.len) {
        const wc: usize = words[i] >> 16;
        const op: u32 = words[i] & 0xffff;
        if (wc == 0 or i + wc > words.len) { i += 1; continue; }
        const result = if (wc >= 3) words[i + 2] else 0;
        if (result < max_id) {
            switch (op) {
                59 => {
                    if (wc >= 4 and words[i + 3] == 12) sb_var[result] = true; // OpVariable StorageBuffer
                },
                65 => {
                    if (wc >= 4) { // OpAccessChain
                        const base = words[i + 3];
                        if (base < max_id and (sb_var[base] or sb_ptr[base])) sb_ptr[result] = true;
                    }
                },
                61 => {
                    if (wc >= 4) { // OpLoad
                        const ptr = words[i + 3];
                        if (ptr < max_id and (sb_ptr[ptr] or sb_var[ptr])) sb_load[result] = true;
                    }
                },
                else => {},
            }
            if (op == 80) is_composite[result] = true; // OpCompositeConstruct
            if (wc >= 4) {
                var operands: [4]u32 = .{ 0, 0, 0, 0 };
                var n: usize = 0;
                for (words[i + 3 .. @min(i + wc, i + 7)]) |operand| {
                    if (n < 4) { operands[n] = operand; n += 1; }
                }
                producers[result] = operands;
            }
        }
        i += wc;
    }
    // Multi-level access chains declared out of order.
    for (0..2) |_| {
        i = 5;
        while (i < words.len) {
            const wc: usize = words[i] >> 16;
            if (wc >= 4 and i + wc <= words.len and (words[i] & 0xffff) == 65) {
                const result = words[i + 2];
                const base = words[i + 3];
                if (result < max_id and base < max_id and (sb_var[base] or sb_ptr[base])) sb_ptr[result] = true;
            }
            i += @max(wc, 1);
        }
    }

    var position_var: u32 = 0;
    i = 5;
    while (i + 3 < words.len) {
        const wc: usize = words[i] >> 16;
        if (wc >= 4 and (words[i] & 0xffff) == 71 and words[i + 2] == 11 and words[i + 3] == 0) { // BuiltIn Position
            const id = words[i + 1];
            var j: usize = 5;
            while (j + 3 < words.len) {
                const jwc: usize = words[j] >> 16;
                if (jwc >= 4 and (words[j] & 0xffff) == 59 and words[j + 2] == id and words[j + 3] == 3) {
                    position_var = id;
                    break;
                }
                j += @max(jwc, 1);
            }
            if (position_var != 0) break;
        }
        i += @max(wc, 1);
    }
    if (position_var == 0) return false;

    var stored: u32 = 0;
    i = 5;
    while (i < words.len) {
        const wc: usize = words[i] >> 16;
        if (wc >= 3 and i + wc <= words.len and (words[i] & 0xffff) == 62 and words[i + 1] == position_var) stored = words[i + 2]; // OpStore
        i += @max(wc, 1);
    }
    if (stored == 0) return false;

    return positionCompositeTracesToStorageLoad(stored, &producers, &is_composite, &sb_load, 0);
}

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
    const local_program: ProgramPair = .{ .vertex = 0x1000000b88, .pixel = 0x1000000ba4 };
    registerShaderFor(local_program, .vertex, &ps_words);
    registerShaderFor(local_program, .pixel, &vs_words);
    const inputs = fragmentInputsFor(local_program).?;
    try std.testing.expectEqual(@as(u32, 1), inputs.allocated); // VS PARAM0 -> bit 0
    try std.testing.expectEqual(inputs.allocated, inputs.enabled);
    const graphics = translatedGraphicsFor(local_program) orelse return error.TestExpectedGraphics;
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
    const local_program: ProgramPair = .{ .vertex = 0x1000000c88, .pixel = 0x1000000ca4 };
    const ps_with_vintrp = [_]u32{
        gcn_decode.vintrp(false, 0, 0, 0), // consumes attr 0
        gcn_decode.vintrp(true, 1, 0, 0),
        0xbf81_0000,
    };
    registerShaderFor(local_program, .vertex, &[_]u32{0xbf81_0000}); // no PARAM exports
    registerShaderFor(local_program, .pixel, &ps_with_vintrp);
    try std.testing.expect(fragmentInputsFor(local_program) == null);
    try std.testing.expect(gcn_translate.lastDiagnostic() != null);
}

test "no synthetic corner fallback in PS4 vertex path" {
    // Correct stage mapping: ps_words exports POS0/PARAM0 (VS); vs_words
    // exports MRT0 with an image sample (PS).
    const res = capture(&real_terraria_dcb).draws[0];
    const src = vertexDataSourceFor(res).?;
    try std.testing.expect(src.address != 0);
    try std.testing.expect(src.size_bytes > 0);
    gcn_translate.registerShaderForWithVertexSource(program, .vertex, &ps_words, src);
    registerShaderFor(program, .pixel, &vs_words);
    const spirv = translatedGraphicsFor(program).?.vertex_words;
    try std.testing.expect(!syntheticCornerSequence(spirv));
    try std.testing.expect(positionTracesToStorageBufferLoad(spirv));
}

test "real VS POS0 reads the staged V# indexed by the draw's sequential VertexIndex" {
    // The classification-accurate VS (ps_words) must contain the reconstructed
    // four-component V# fetch, indexed by v4 (the sequential VertexIndex), not
    // a synthetic quad corner.
    var decoded = try gcn_decode.decodeVertexToRdna2(std.testing.allocator, &ps_words);
    defer decoded.deinit(std.testing.allocator);
    var fetch_count: usize = 0;
    for (decoded.program.instructions.items) |inst| {
        if (inst.opcode != .buffer_load_format_xyzw) continue;
        fetch_count += 1;
        try std.testing.expect(inst.index_enable);
        try std.testing.expectEqual(@as(u32, 4), inst.src0.reg); // vaddr = v4
        try std.testing.expectEqual(@as(u32, 4), inst.src1.reg); // V# at descriptor 0
    }
    try std.testing.expectEqual(@as(usize, 1), fetch_count);

    const res = capture(&real_terraria_dcb).draws[0];
    gcn_translate.registerShaderForWithVertexSource(program, .vertex, &ps_words, vertexDataSourceFor(res));
    registerShaderFor(program, .pixel, &vs_words);
    const spirv = translatedGraphicsFor(program).?.vertex_words;
    // BuiltIn VertexIndex (decoration 11 / value 42) is present in the VS.
    var has_vertex_index = false;
    var i: usize = 5;
    while (i + 3 < spirv.len) {
        const wc: usize = spirv[i] >> 16;
        if (wc >= 4 and (spirv[i] & 0xffff) == 71 and spirv[i + 2] == 11 and spirv[i + 3] == 42) has_vertex_index = true;
        i += @max(wc, 1);
    }
    try std.testing.expect(has_vertex_index);
}

test "V# fetch reconstruction is gated to the exact Terraria VS signature" {
    // The real captured VS matches the narrow prolog signature and is injected.
    try std.testing.expect(gcn_decode.isTerrariaVertexShader(&ps_words));

    // A different synthetic VS that also exports POS0 must NOT be injected: no
    // MUBUF fetch, no VertexIndex seed, so its own POS0 data flow is untouched.
    const other_vs = [_]u32{
        gcn_decode.vop2(0x08, 4, 4, 0x102), // v_mul_f32 v4, v4, 1.0
        gcn_decode.exp(0x0c, 0xf, true, .{ 4, 4, 4, 4 })[0],
        gcn_decode.exp(0x0c, 0xf, true, .{ 4, 4, 4, 4 })[1],
        0xbf81_0000,
    };
    try std.testing.expect(!gcn_decode.isTerrariaVertexShader(&other_vs));
    var decoded = try gcn_decode.decodeToRdna2(std.testing.allocator, &other_vs);
    defer decoded.deinit(std.testing.allocator);
    for (decoded.program.instructions.items) |inst|
        try std.testing.expect(inst.opcode != .buffer_load_format_xyzw);

    const other_program: ProgramPair = .{ .vertex = 0x1000000e88, .pixel = 0x1000000ea4 };
    registerShaderFor(other_program, .vertex, &other_vs);
    registerShaderFor(other_program, .pixel, &ps_words);
    const spirv = translatedGraphicsFor(other_program).?.vertex_words;
    var has_vertex_index = false;
    var i: usize = 5;
    while (i + 3 < spirv.len) {
        const wc: usize = spirv[i] >> 16;
        if (wc >= 4 and (spirv[i] & 0xffff) == 71 and spirv[i + 2] == 11 and spirv[i + 3] == 42) has_vertex_index = true;
        i += @max(wc, 1);
    }
    try std.testing.expect(!has_vertex_index);
}

test "vertexDataSourceFor reports null with a diagnostic when no VS V# exists" {
    const empty: gcn_resources.Resources = .{};
    try std.testing.expect(vertexDataSourceFor(empty) == null);
    try std.testing.expect(gcn_translate.lastDiagnostic() != null);
}
