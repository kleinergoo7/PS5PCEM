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
const gcn_resources = @import("gcn_resources.zig");

pub const ProgramPair = gcn_resources.ProgramPair;

pub const Stage = enum { vertex, pixel };

pub const TranslatedGraphics = struct {
    vertex_words: []const u32,
    fragment_words: []const u32,
};

/// Which VS PARAM exports the paired PS consumes. Bits are raw VINTRP ATTR /
/// VS PARAM indices; allocated and enabled are identical because GCN PARAM
/// exports are always both allocated and enabled.
pub const FragmentInputs = struct { allocated: u32, enabled: u32 };

/// Guest vertex bytes backing the VS: the base, length and element stride of a
/// captured GCN V# descriptor. The backend stages exactly this range into the
/// storage buffer declared by `buildOptions`; nothing is synthesized.
pub const VertexDataSource = struct { address: u64, size_bytes: u32, stride: u32 };

/// Select the VS V# with the smallest nonzero stride whose base is a plausible
/// guest address. V# descriptors come from the captured SET_SH_REG stream, so a
/// settled binding with a nonzero base is the guest-readable source. Returns
/// null with a diagnostic when none exists — never fabricate vertex positions.
pub fn vertexDataSourceFor(res: gcn_resources.Resources) ?VertexDataSource {
    var best: ?VertexDataSource = null;
    for (res.bindings[0..res.count]) |binding| {
        if (binding.stage != .vertex or binding.descriptor.kind != .constant_buffer) continue;
        if (binding.descriptor.address < 0x1000 or binding.descriptor.size_bytes == 0) continue;
        const words = res.words(binding);
        const stride: u32 = (words[1] >> 16) & 0x3fff;
        if (stride == 0) continue;
        const size: u32 = @truncate(@min(binding.descriptor.size_bytes, std.math.maxInt(u32)));
        if (size == 0) continue;
        if (best == null or stride < best.?.stride) {
            best = .{ .address = binding.descriptor.address, .size_bytes = size, .stride = stride };
        }
    }
    if (best == null) diagnostic = .{ .stage = .vertex, .reason = "no usable VS V# descriptor" };
    return best;
}

/// USER_DATA word index backing the registered PS's sampled image. GNM writes
/// each T# as a contiguous 8-word SET_SH_REG block at USER_DATA base + index,
/// and patches the MIMG resource operand to name that same word index. So the
/// decoded `Mimg.tsgpr` (equivalently `SampledImageBinding.resource_sgpr`) is
/// the slot the shader actually samples. Returns null without a registered PS
/// or when that PS samples no image.
pub fn sampledImageUserIndexFor(program: ProgramPair) ?u8 {
    lockGlobal();
    defer lock.unlock();
    const index = findEntry(program) orelse return null;
    const isa = registry[index].pixel_isa orelse return null;
    var it = gcn_decode.decode(isa);
    while (true) {
        const maybe = it.next() catch return null;
        const inst = maybe orelse break;
        switch (inst) {
            .image_sample => |sample| {
                const word_index = sample.tsgpr;
                if (word_index >= gcn_resources.user_data_words) return null;
                return @intCast(word_index);
            },
            else => {},
        }
    }
    return null;
}

/// PS4-only dynamic scalar layout. One slot per SGPR the GCN program reads plus
/// one slot per SMEM destination word, in a deterministic order. The draw path
/// uploads values in exactly this order; the writer loads slot N from
/// `dynamic_scalar_binding.value_base + N`.
pub const ScalarSlot = rdna2.spirv.ScalarRegister;

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
    return translateShaderSlots(allocator, stage, words, null, null, null);
}

/// Same as `translateShader`, but also returns the owned dynamic scalar layout
/// used by `options.scalar_registers`. The draw path consumes this layout.
/// `fragment_inputs` is the paired VS/PS interface; `vertex_source` is the
/// measured V# that supplies the PS4 vertex fetch. Standalone translations
/// leave both null and keep the legacy all-inputs / fixed-stride default.
fn translateShaderSlots(
    allocator: std.mem.Allocator,
    stage: Stage,
    words: []const u32,
    slots_out: ?*[]ScalarSlot,
    fragment_inputs: ?FragmentInputs,
    vertex_source: ?VertexDataSource,
) Error![]u32 {
    var seen = gcn_decode.decode(words);
    while (try seen.next()) |inst| {
        if (inst.tag() == .unsupported) return error.UnsupportedInstruction;
    }

    // Only the exact captured Terraria VS gets the reconstructed V# fetch;
    // every other PS4 VS keeps its own POS0 data flow untouched.
    const terraria_vs = stage == .vertex and gcn_decode.isTerrariaVertexShader(words);
    var decoded = if (terraria_vs)
        try gcn_decode.decodeVertexToRdna2(allocator, words)
    else
        try gcn_decode.decodeToRdna2(allocator, words);
    defer decoded.deinit(allocator);

    // Real Terraria vertex shaders use IMAGE_SAMPLE with implicit LOD for
    // vertex texture fetches. The shared writer only permits level-zero /
    // explicit LOD in the vertex stage, and GCN VTF is LOD 0 by definition.
    if (stage == .vertex) {
        for (decoded.program.instructions.items) |*inst| {
            if (inst.opcode == .image_sample) inst.image_sample_flags.level_zero = true;
        }
    }

    const slots = try buildScalarSlots(allocator, &decoded.program);
    var handed_off = false;
    defer if (!handed_off) allocator.free(slots);

    var options = try buildOptions(allocator, stage, &decoded.program, slots, fragment_inputs, vertex_source, terraria_vs);
    defer options.deinit();

    var module = try rdna2.translateProgramSpirv(allocator, &decoded.program, options.options);
    defer module.deinit(allocator);
    const spirv_words = try allocator.dupe(u32, module.words);
    if (slots_out) |out| {
        out.* = slots;
        handed_off = true;
    }
    return spirv_words;
}

/// Collect SGPR provenance for the decoded program. SMEM destination words get
/// `producer_pc` so `rdna2` replaces the load with a dynamic scalar load; every
/// other SGPR read gets an entry-time slot. Values are placeholders — the real
/// values are uploaded per draw.
fn buildScalarSlots(allocator: std.mem.Allocator, program: *const rdna2.Program) Error![]ScalarSlot {
    var slots: std.ArrayList(ScalarSlot) = .empty;
    errdefer slots.deinit(allocator);

    // Pass 1: SMEM destinations, in program order. `rdna2` requires every word
    // of a multi-dword load to share the producer PC.
    for (program.instructions.items) |inst| {
        if (inst.family != .smem) continue;
        const dst = switch (inst.dst.kind) {
            .sgpr => inst.dst.reg,
            else => continue,
        };
        const count: usize = @max(inst.data_words, 1);
        if (dst + count > 128) continue;
        for (0..count) |word| {
            try slots.append(allocator, .{
                .register = @intCast(dst + word),
                .value = 0,
                .producer_pc = inst.pc,
            });
        }
    }

    // Pass 2: entry-time SGPR reads not already produced by an SMEM load.
    var covered: [128]bool = @splat(false);
    for (slots.items) |slot| covered[slot.register] = true;
    for (program.instructions.items) |inst| {
        var sources = inst.sources();
        for (sources.slice()) |source| {
            if (source.kind != .sgpr or source.reg >= 128) continue;
            if (covered[source.reg]) continue;
            covered[source.reg] = true;
            try slots.append(allocator, .{ .register = source.reg, .value = 0 });
        }
    }
    return try slots.toOwnedSlice(allocator);
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

/// Fallback element stride when no V# was measured (standalone translations).
/// The registered PS4 path passes the real stride from `vertexDataSourceFor`.
/// shortcut: Terraria's captured V# is 16 bytes; upgrade if a PS4 title reaches
/// translation without a measured source and strides its V# differently.
const ps4_vertex_v_stride_fallback: u32 = 16;

fn buildOptions(allocator: std.mem.Allocator, stage: Stage, program: *const rdna2.Program, slots: []const ScalarSlot, fragment_inputs: ?FragmentInputs, vertex_source: ?VertexDataSource, terraria_vs: bool) Error!OptionsBuilder {
    var builder = OptionsBuilder{ .allocator = allocator };
    errdefer builder.deinit();

    // The PS4 VS front-end inserts a MUBUF that reads POS0 from descriptor 0.
    // Its stride is the measured V# stride when the caller has one; the host
    // staging uses the same source, so the addressed record is real guest data,
    // not a synthetic corner.
    const vertex_stride = if (vertex_source) |src| src.stride else ps4_vertex_v_stride_fallback;

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
                .stride = if (stage == .vertex) vertex_stride else 4,
                // PS4 VS: the guest prolog computes a sequential index from the
                // VertexIndex built-in (v4); do not override it on any stage.
                .use_vertex_index = stage != .vertex,
            });
        }
    }

    // The pixel stage uses the interface derived from the paired VS PARAM
    // exports and VINTRP attrs. A standalone translation (no registered pair)
    // keeps the legacy all-inputs default; the writer still infers
    // parameter_mask/color_export_mask from decoded VINTRP and EXP.
    // PS4-only: SGPR-backed values are host-updated per draw instead of baked
    // into OpConstant. Binding 34 is the backend's dedicated dynamic scalar
    // storage buffer (2 + maximum_storage_images); the fragment stage uses a
    // disjoint value_base so writeGraphicsScalarValues can fill both stages.
    const fragment_words_per_stage: u32 = 512 * 16 + 128 * 2;
    const derived_inputs = if (stage == .pixel) fragment_inputs else null;
    const inputs = derived_inputs orelse FragmentInputs{ .allocated = 0b11, .enabled = 0b11 };
    builder.options = .{
        .stage = if (stage == .vertex) .vertex else .fragment,
        .sampled_images = builder.images.items,
        .storage_buffers = builder.buffers.items,
        .fragment_inputs = .{
            .allocated = @intCast(inputs.allocated),
            .enabled = @intCast(inputs.enabled),
        },
        // The lowest exported PARAM slot is the guest UV. Only set for a
        // registered pair with a real VS PARAM export, never on PS5/native.
        .ps4_sample_coordinate_location = if (derived_inputs != null and inputs.allocated != 0)
            @intCast(@ctz(inputs.allocated))
        else
            null,
        .scalar_registers = slots,
        // PS4 no longer seeds float quad corners from VertexIndex: POS0 comes
        // from guest V#-derived values staged by the backend. The shared
        // writer's override option stays default-off and native-identical.
        .vertex_corner_vgprs = null,
        .vertex_position_corner_override = false,
        // Only the reconstructed Terraria fetch is indexed by v4; DRAW_INDEX_AUTO
        // count=4 is replayed as four sequential vertices. Other VS programs
        // keep v4 for their own purposes.
        .vertex_index_vgpr = if (terraria_vs) 4 else null,
        .dynamic_scalar_binding = if (slots.len != 0) .{
            .binding = 2 + rdna2.spirv.maximum_storage_images,
            .value_base = if (stage == .vertex) 0 else fragment_words_per_stage,
        } else null,
        .specialized_scalar_prefix_end = std.math.maxInt(u32),
    };
    return builder;
}

// Registered shader state. One bounded entry per bound GNM program pair; each
// entry owns copies of both stage ISAs and, once both are present, the
// translated SPIR-V words and dynamic scalar layouts. Changing either stage
// invalidates and rebuilds that pair's translation.
var lock: std.atomic.Mutex = .unlocked;

fn lockGlobal() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

const max_registrations = 8;

const ShaderTranslation = struct {
    program: ProgramPair = .{},
    used: bool = false,
    vertex_isa: ?[]u32 = null,
    pixel_isa: ?[]u32 = null,
    vertex_spirv: ?[]u32 = null,
    pixel_spirv: ?[]u32 = null,
    vertex_slots: []ScalarSlot = &.{},
    pixel_slots: []ScalarSlot = &.{},
    vertex_source: ?VertexDataSource = null,

    fn freeTranslation(self: *ShaderTranslation, allocator: std.mem.Allocator) void {
        if (self.vertex_spirv) |words| allocator.free(words);
        if (self.pixel_spirv) |words| allocator.free(words);
        if (self.vertex_slots.len != 0) allocator.free(self.vertex_slots);
        if (self.pixel_slots.len != 0) allocator.free(self.pixel_slots);
        self.vertex_spirv = null;
        self.pixel_spirv = null;
        self.vertex_slots = &.{};
        self.pixel_slots = &.{};
    }

    fn deinit(self: *ShaderTranslation, allocator: std.mem.Allocator) void {
        if (self.vertex_isa) |words| allocator.free(words);
        if (self.pixel_isa) |words| allocator.free(words);
        self.freeTranslation(allocator);
        self.* = .{};
    }
};

var registry: [max_registrations]ShaderTranslation = [_]ShaderTranslation{.{}} ** max_registrations;
var next_slot: usize = 0;
var diagnostic: ?Diagnostic = null;

fn findEntry(program: ProgramPair) ?usize {
    for (&registry, 0..) |*entry, i| {
        if (entry.used and entry.program.vertex == program.vertex and entry.program.pixel == program.pixel) return i;
    }
    return null;
}

/// Derive the fragment-input mask from the VS PARAM exports, then verify that
/// every VINTRP attribute the PS consumes is actually exported. A mismatch
/// reports a diagnostic and returns null rather than inventing an input.
fn fragmentInputsFromIsa(vertex_isa: []const u32, pixel_isa: []const u32) ?FragmentInputs {
    var mask: u32 = 0;
    var vs = gcn_decode.decode(vertex_isa);
    while (true) {
        const inst = vs.next() catch {
            diagnostic = .{ .stage = .vertex, .reason = "cannot decode VS PARAM exports" };
            return null;
        } orelse break;
        switch (inst) {
            .exp => |exported| {
                if (exported.target >= 0x20) {
                    mask |= @as(u32, 1) << @intCast(@as(u32, exported.target) - 0x20);
                }
            },
            else => {},
        }
    }

    var ps = gcn_decode.decode(pixel_isa);
    while (true) {
        const inst = ps.next() catch {
            diagnostic = .{ .stage = .pixel, .reason = "cannot decode PS VINTRP attrs" };
            return null;
        } orelse break;
        const attr: ?u32 = switch (inst) {
            .v_interp_p1_f32, .v_interp_p2_f32 => |vintrp| vintrp.attr,
            else => null,
        };
        if (attr) |index| {
            if (index >= 32 or mask & (@as(u32, 1) << @intCast(index)) == 0) {
                diagnostic = .{ .stage = .pixel, .reason = "VINTRP attr has no matching VS PARAM export" };
                return null;
            }
        }
    }
    return .{ .allocated = mask, .enabled = mask };
}

/// Fragment-input mask for an exact registered program pair, or null when
/// either stage is missing or a VINTRP attribute has no VS PARAM export.
pub fn fragmentInputsFor(program: ProgramPair) ?FragmentInputs {
    lockGlobal();
    defer lock.unlock();
    const index = findEntry(program) orelse return null;
    const entry = &registry[index];
    if (entry.vertex_isa == null or entry.pixel_isa == null) return null;
    return fragmentInputsFromIsa(entry.vertex_isa.?, entry.pixel_isa.?);
}

/// Register one stage's ISA for an exact GNM program pair, supplying the
/// measured VS V# so the translator's element stride matches the bytes the
/// backend stages. When both stages are present the pair is (re)translated; a
/// single stage alone never produces a usable translation.
pub fn registerShaderForWithVertexSource(program: ProgramPair, stage: Stage, words: []const u32, vertex_source: ?VertexDataSource) void {
    const allocator = std.heap.page_allocator;
    const copy = allocator.dupe(u32, words) catch return;

    lockGlobal();
    defer lock.unlock();

    const index = findEntry(program) orelse blk: {
        var free_slot: ?usize = null;
        for (&registry, 0..) |*entry, i| {
            if (!entry.used) {
                free_slot = i;
                break;
            }
        }
        const slot = free_slot orelse next_slot;
        next_slot = (slot + 1) % max_registrations;
        registry[slot].deinit(allocator); // recycle a fresh or evicted slot
        registry[slot].program = program;
        registry[slot].used = true;
        break :blk slot;
    };
    var entry = &registry[index];

    const isa_slot = if (stage == .vertex) &entry.vertex_isa else &entry.pixel_isa;
    if (isa_slot.*) |old| allocator.free(old);
    isa_slot.* = copy;
    if (stage == .vertex) entry.vertex_source = vertex_source;

    // A change to either stage invalidates the whole pair's translation.
    entry.freeTranslation(allocator);
    diagnostic = null;
    if (entry.vertex_isa == null or entry.pixel_isa == null) return;

    // A mismatch declares no inputs (with a diagnostic) instead of reverting
    // to the guessed all-inputs default.
    const fragment_inputs = fragmentInputsFromIsa(entry.vertex_isa.?, entry.pixel_isa.?) orelse
        FragmentInputs{ .allocated = 0, .enabled = 0 };
    var vertex_slots: []ScalarSlot = &.{};
    const vertex_words = translateShaderSlots(allocator, .vertex, entry.vertex_isa.?, &vertex_slots, null, entry.vertex_source) catch |err| {
        diagnostic = .{ .stage = .vertex, .reason = @errorName(err) };
        return;
    };
    var pixel_slots: []ScalarSlot = &.{};
    const pixel_words = translateShaderSlots(allocator, .pixel, entry.pixel_isa.?, &pixel_slots, fragment_inputs, null) catch |err| {
        allocator.free(vertex_words);
        if (vertex_slots.len != 0) allocator.free(vertex_slots);
        diagnostic = .{ .stage = .pixel, .reason = @errorName(err) };
        return;
    };

    entry.vertex_spirv = vertex_words;
    entry.pixel_spirv = pixel_words;
    entry.vertex_slots = vertex_slots;
    entry.pixel_slots = pixel_slots;
}

/// Register one stage without a measured V# (standalone translation).
pub fn registerShaderFor(program: ProgramPair, stage: Stage, words: []const u32) void {
    registerShaderForWithVertexSource(program, stage, words, null);
}

/// Test helper: register against the zero program pair.
pub fn registerShader(stage: Stage, words: []const u32) void {
    registerShaderFor(.{}, stage, words);
}

/// Dynamic scalar layout for an exact program pair/stage. The draw path fills
/// values in this exact order before `writeGraphicsScalarValues`.
pub fn scalarSlotsFor(program: ProgramPair, stage: Stage) []const ScalarSlot {
    lockGlobal();
    defer lock.unlock();
    const index = findEntry(program) orelse return &.{};
    const entry = &registry[index];
    return if (stage == .vertex) entry.vertex_slots else entry.pixel_slots;
}

/// Test helper over the zero program pair.
pub fn scalarSlots(stage: Stage) []const ScalarSlot {
    return scalarSlotsFor(.{}, stage);
}

/// Returns the translated stage outputs for an exact program pair, or null
/// unless both stages for that pair are present and translated successfully.
pub fn translatedGraphicsFor(program: ProgramPair) ?TranslatedGraphics {
    lockGlobal();
    defer lock.unlock();
    const index = findEntry(program) orelse return null;
    const entry = &registry[index];
    if (entry.vertex_spirv == null or entry.pixel_spirv == null) return null;
    return .{ .vertex_words = entry.vertex_spirv.?, .fragment_words = entry.pixel_spirv.? };
}

/// Test helper over the zero program pair.
pub fn translatedGraphics() ?TranslatedGraphics {
    return translatedGraphicsFor(.{});
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

test "translated VS loads SGPR scalars dynamically from the dedicated binding" {
    // v_mov_b32 v0, s8 followed by a POS0 export: s8 must become an
    // OpAccessChain + OpLoad from binding 34, not an OpConstant.
    const vs = [_]u32{
        gcn_decode.vop1(1, 0, 8),
        gcn_decode.exp(0, 0xf, true, .{ 0, 0, 0, 0 })[0],
        gcn_decode.exp(0, 0xf, true, .{ 0, 0, 0, 0 })[1],
        0xbf81_0000,
    };
    const words = try translateShader(std.testing.allocator, .vertex, &vs);
    defer std.testing.allocator.free(words);

    try std.testing.expect(containsOpcode(words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(words, 61)); // OpLoad
    var found_binding = false;
    for (words, 0..) |word, i| {
        if (i + 3 >= words.len) break;
        if (word == 0x0004_0047 and words[i + 2] == 2 + rdna2.spirv.maximum_storage_images and words[i + 3] == 0) {
            found_binding = true;
        }
    }
    try std.testing.expect(found_binding);

    // This hand-built VS lacks the Terraria prolog signature, so neither the
    // old quad-corner seed nor the reconstructed v4 V# index is applied.
    var found_vertex_index = false;
    for (words, 0..) |word, i| {
        if (i + 3 >= words.len) break;
        if (word == 0x0004_0047 and words[i + 2] == 11 and words[i + 3] == 42) found_vertex_index = true;
    }
    try std.testing.expect(!found_vertex_index);

    // Slot order is stable: the same GCN program always yields the same layout.
    var decoded = try gcn_decode.decodeToRdna2(std.testing.allocator, &vs);
    defer decoded.deinit(std.testing.allocator);
    const slots = try buildScalarSlots(std.testing.allocator, &decoded.program);
    defer std.testing.allocator.free(slots);
    try std.testing.expect(slots.len > 0);
    try std.testing.expectEqual(@as(u32, 8), slots[0].register);
}

test "dynamic scalar values do not change translated SPIR-V words" {
    // The host uploads values into the scalar buffer per draw; translation is
    // independent of them, matching rdna2's dynamic-scalar contract.
    const vs = [_]u32{
        gcn_decode.vop1(1, 0, 8),
        gcn_decode.exp(0, 0xf, true, .{ 0, 0, 0, 0 })[0],
        gcn_decode.exp(0, 0xf, true, .{ 0, 0, 0, 0 })[1],
        0xbf81_0000,
    };
    var decoded = try gcn_decode.decodeToRdna2(std.testing.allocator, &vs);
    defer decoded.deinit(std.testing.allocator);
    const slots = try buildScalarSlots(std.testing.allocator, &decoded.program);
    defer std.testing.allocator.free(slots);

    const first_values = try std.testing.allocator.dupe(ScalarSlot, slots);
    defer std.testing.allocator.free(first_values);
    const second_values = try std.testing.allocator.dupe(ScalarSlot, slots);
    defer std.testing.allocator.free(second_values);
    for (second_values) |*slot| slot.value = 0xdead_beef;

    var first_options = try buildOptions(std.testing.allocator, .vertex, &decoded.program, first_values, null, null, false);
    defer first_options.deinit();
    var second_options = try buildOptions(std.testing.allocator, .vertex, &decoded.program, second_values, null, null, false);
    defer second_options.deinit();
    var first_module = try rdna2.translateProgramSpirv(std.testing.allocator, &decoded.program, first_options.options);
    defer first_module.deinit(std.testing.allocator);
    var second_module = try rdna2.translateProgramSpirv(std.testing.allocator, &decoded.program, second_options.options);
    defer second_module.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, first_module.words, second_module.words);
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
