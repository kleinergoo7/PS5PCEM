// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 GCN → SPIR-V translation, reusing the shared `rdna2` writer.
//!
//! No SPIR-V is emitted here: decoded/spilled GCN words are normalized by
//! `gcn_decode`, a small PS4 resource/options builder fills the stub bindings
//! the RDNA2 pipeline expects, and `rdna2.translateProgramSpirv` does all the
//! emission. Integration seam for the PS4-gated draw path.

const std = @import("std");
const rdna2 = @import("rdna2");
const gcn_decode = @import("gcn_decode.zig");

pub const Stage = enum { vertex, pixel };

pub const TranslatedGraphics = struct {
    vertex_words: []const u32,
    fragment_words: []const u32,
};

pub const Error = error{
    NoShader,
    UnsupportedInstruction,
    NoSampledImage,
} || std.mem.Allocator.Error || rdna2.Error || rdna2.spirv.Error;

pub const Diagnostic = struct {
    stage: Stage,
    reason: []const u8,
};

/// Translate a raw GCN word stream into owned SPIR-V words. Unsupported
/// instructions are reported as an error instead of being silently dropped.
pub fn translateShader(allocator: std.mem.Allocator, stage: Stage, words: []const u32) Error![]u32 {
    var seen = gcn_decode.decode(words);
    while (try seen.next()) |inst| {
        if (inst.tag() == .unsupported) return error.UnsupportedInstruction;
    }

    var decoded = try gcn_decode.decodeToRdna2(allocator, words);
    defer decoded.deinit(allocator);

    // Real Terraria vertex shaders use IMAGE_SAMPLE with implicit LOD for
    // vertex texture fetches. The shared writer only permits level-zero /
    // explicit LOD in the vertex stage, and GCN VTF is LOD 0 by definition.
    if (stage == .vertex) {
        for (decoded.program.instructions.items) |*inst| {
            if (inst.opcode == .image_sample) inst.image_sample_flags.level_zero = true;
        }
    }

    var options = try buildOptions(allocator, stage, &decoded.program);
    defer options.deinit();

    var module = try rdna2.translateProgramSpirv(allocator, &decoded.program, options.options);
    defer module.deinit(allocator);
    return try allocator.dupe(u32, module.words);
}

/// PS4 resource/options builder. Milestone 1 derives sampled images and vertex
/// buffers from the decoded instructions; GNM T#/S#/V# descriptors and
/// SPI_PS_INPUT_* state are not recovered from guest memory yet.
const OptionsBuilder = struct {
    allocator: std.mem.Allocator,
    images: std.ArrayList(rdna2.spirv.SampledImageBinding) = .empty,
    buffers: std.ArrayList(rdna2.spirv.StorageBufferBinding) = .empty,
    options: rdna2.spirv.Options = undefined,

    fn deinit(self: *OptionsBuilder) void {
        self.images.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
    }
};

fn buildOptions(allocator: std.mem.Allocator, stage: Stage, program: *const rdna2.Program) Error!OptionsBuilder {
    var builder = OptionsBuilder{ .allocator = allocator };
    errdefer builder.deinit();

    for (program.instructions.items) |inst| {
        if (inst.opcode == .image_sample) {
            try builder.images.append(allocator, .{
                .resource_sgpr = inst.src1.reg,
                .sampler_sgpr = inst.src2.reg,
                .descriptor_index = rdna2.spirv.sampled_image_2d_descriptor_binding,
                .dimension = .two_d,
            });
        } else if (inst.opcode == .buffer_load_format_xyzw or inst.opcode == .buffer_load_format_xy) {
            try builder.buffers.append(allocator, .{
                .resource_sgpr = inst.src1.reg,
                .descriptor_index = @intCast(builder.buffers.items.len),
                .stride = 4,
                .use_vertex_index = true,
            });
        }
    }

    // Two interpolated PS inputs (TEXCOORD0/COLOR0) is the sprite-shader
    // convention; the writer infers parameter_mask/color_export_mask from the
    // decoded VINTRP and EXP instructions themselves.
    builder.options = .{
        .stage = if (stage == .vertex) .vertex else .fragment,
        .sampled_images = builder.images.items,
        .storage_buffers = builder.buffers.items,
        .fragment_inputs = .{ .allocated = 0b11, .enabled = 0b11 },
    };
    return builder;
}

// Registered shader state. `registerShader` owns copies of both the ISA and
// the translated words; changing either stage invalidates its translation.
var lock: std.atomic.Mutex = .unlocked;

fn lockGlobal() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}
var vertex_isa: ?[]u32 = null;
var pixel_isa: ?[]u32 = null;
var vertex_spirv: ?[]u32 = null;
var pixel_spirv: ?[]u32 = null;
var diagnostic: ?Diagnostic = null;

pub fn registerShader(stage: Stage, words: []const u32) void {
    const allocator = std.heap.page_allocator;
    const copy = allocator.dupe(u32, words) catch return;

    lockGlobal();
    defer lock.unlock();

    const isa_slot = if (stage == .vertex) &vertex_isa else &pixel_isa;
    const spirv_slot = if (stage == .vertex) &vertex_spirv else &pixel_spirv;
    if (isa_slot.*) |old| allocator.free(old);
    isa_slot.* = copy;
    if (spirv_slot.*) |old| {
        allocator.free(old);
        spirv_slot.* = null;
    }

    diagnostic = null;
    const translated = translateShader(allocator, if (stage == .vertex) .vertex else .pixel, copy) catch |err| {
        diagnostic = .{ .stage = if (stage == .vertex) .vertex else .pixel, .reason = @errorName(err) };
        return;
    };
    spirv_slot.* = translated;
}

/// Returns the translated stage outputs, or null until both a real vertex and
/// pixel shader have been registered and translated successfully.
pub fn translatedGraphics() ?TranslatedGraphics {
    lockGlobal();
    defer lock.unlock();
    if (vertex_spirv == null or pixel_spirv == null) return null;
    return .{ .vertex_words = vertex_spirv.?, .fragment_words = pixel_spirv.? };
}

pub fn lastDiagnostic() ?Diagnostic {
    lockGlobal();
    defer lock.unlock();
    return diagnostic;
}

// ---- tests ----

const sprite_ps = [_]u32{
    gcn_decode.vintrp(false, 0, 0, 0),
    gcn_decode.vintrp(true, 1, 0, 0),
    gcn_decode.vintrp(false, 2, 1, 0),
    gcn_decode.vintrp(true, 3, 1, 0),
    0xbf8c_0000,
    gcn_decode.mimg(0x20, 0xf, 4, 0, 0, 2)[0],
    gcn_decode.mimg(0x20, 0xf, 4, 0, 0, 2)[1],
    gcn_decode.vop2(0x08, 4, 4, 0x102),
    gcn_decode.exp(0, 0xf, true, .{ 4, 4, 4, 4 })[0],
    gcn_decode.exp(0, 0xf, true, .{ 4, 4, 4, 4 })[1],
    0xbf81_0000,
};

fn containsOpcode(words: []const u32, opcode: u16) bool {
    for (words) |word| if (word & 0xffff == opcode) return true;
    return false;
}

/// Location 0 is the MRT0 color attachment: OpDecorate <id> Location 0.
fn exportsToLocationZero(words: []const u32) bool {
    for (words, 0..) |word, i| {
        if (i + 3 >= words.len) break;
        if (word == 0x0004_0047 and words[i + 2] == 30 and words[i + 3] == 0) return true;
    }
    return false;
}

test "GCN sprite pixel shader translates through the shared SPIR-V writer" {
    const words = try translateShader(std.testing.allocator, .pixel, &sprite_ps);
    defer std.testing.allocator.free(words);

    try std.testing.expect(words.len > 0);
    try std.testing.expect(containsOpcode(words, 87)); // OpImageSampleImplicitLod
    try std.testing.expect(containsOpcode(words, 133)); // OpFMul
    try std.testing.expect(exportsToLocationZero(words)); // EXP MRT0 → Location 0
}

test "vertex exports translate through the shared SPIR-V writer" {
    const vs = [_]u32{
        gcn_decode.exp(0, 0xf, true, .{ 0, 1, 2, 3 })[0], // exp pos 0
        gcn_decode.exp(0, 0xf, true, .{ 0, 1, 2, 3 })[1],
        gcn_decode.exp(0x20, 0xf, false, .{ 4, 5, 6, 7 })[0], // exp param 0
        gcn_decode.exp(0x20, 0xf, false, .{ 4, 5, 6, 7 })[1],
        0xbf81_0000,
    };
    const words = try translateShader(std.testing.allocator, .vertex, &vs);
    defer std.testing.allocator.free(words);
    try std.testing.expect(words.len > 0); // vertex stage emits position + PARAM outputs
}

test "unsupported GCN instructions are reported, not silently dropped" {
    const with_ds = [_]u32{ 0xd800_0000, 0x0000_0000, 0xbf81_0000 };
    try std.testing.expectError(error.UnsupportedInstruction, translateShader(std.testing.allocator, .pixel, &with_ds));

    // A bad opcode inside a known family must be reported too.
    const bad_vop2 = [_]u32{ gcn_decode.vop2(0x2a, 2, 1, 0x101), 0xbf81_0000 };
    try std.testing.expectError(error.UnsupportedInstruction, translateShader(std.testing.allocator, .pixel, &bad_vop2));
}

test "registration copies ISA, is null until both stages exist, and invalidates on change" {
    const vertex_ps = [_]u32{
        0xbf81_0000, // s_endpgm: minimal but valid vertex program
    };
    try std.testing.expect(translatedGraphics() == null);
    registerShader(.vertex, &vertex_ps);
    try std.testing.expect(translatedGraphics() == null);
    registerShader(.pixel, &sprite_ps);
    const both = translatedGraphics() orelse return error.TestExpectedGraphics;
    try std.testing.expect(both.vertex_words.len > 0);
    try std.testing.expect(both.fragment_words.len > 0);

    registerShader(.pixel, &[_]u32{ 0xd800_0000, 0, 0xbf81_0000 });
    try std.testing.expect(translatedGraphics() == null);
    try std.testing.expectEqual(Stage.pixel, (lastDiagnostic() orelse return error.TestExpectedDiagnostic).stage);
    registerShader(.pixel, &sprite_ps); // restore for any later tests
}
