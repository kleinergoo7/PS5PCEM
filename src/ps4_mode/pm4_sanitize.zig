// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 GCN PM4 → shared-executor sanitizer (PS4-only).
//!
//! PS4 GNM command buffers are genuine Type-3 PM4, but they are not laid out
//! the way the shared RDNA2 walker expects:
//!   * GCN register offsets can exceed the retained register files (context
//!     0x400, shader 0x300, config 0xc00, uconfig 0x4000). The first such write
//!     makes the shared executor return RegisterOutOfRange and stop the queue.
//!   * A GCN packet whose body length runs over the following header, plus
//!     bare data/reserved words, makes the walker stop early — discarding the
//!     draws and EOP events that appear later in the same DCB.
//!
//! This module re-emits only packets that are genuinely present in the guest
//! buffer: recognised Type-3 opcodes with a body that fits, in original order.
//! Out-of-range register packets and non-packet words are dropped. The sole
//! addition is the PS4-specific render-target prefix below, derived from the
//! guest's own CB registers; no PS5/native stream is touched and the shared
//! executor's register-range check is left intact.

const std = @import("std");

pub const Stats = struct {
    /// Packets copied through unchanged.
    kept: usize = 0,
    /// Direct register packets removed, by bank.
    dropped_config: usize = 0,
    dropped_context: usize = 0,
    dropped_shader: usize = 0,
    dropped_uconfig: usize = 0,
    /// Words that were not a recognised PM4 packet header (garbage/padding).
    skipped_words: usize = 0,
};

// PM4 header fields — identical to gpu/pm4.zig, kept local so this module
// stays std-only and testable in isolation.
const kind_shift: u5 = 30;
const count_shift: u5 = 16;
const count_mask: u32 = 0x3fff;
const opcode_shift: u5 = 8;

/// Width/height used to fill the render-target dimension register when a GCN
/// DCB omits it. 1920x1080 is the PS4 VideoOut HD output (the emulator's
/// VideoOut window); a first frame only needs a valid extent, not the title's
/// exact internal resolution.
pub const Dimensions = struct {
    width: u32 = 1920,
    height: u32 = 1080,
};

/// Worst case: 8 colour slots × 3 registers × (header + offset + value).
pub const max_synthesized_dwords: usize = 8 * 3 * 3;

/// PS/VS program address registers, written as two SET_SH_REG packets.
pub const max_shader_reg_dwords: usize = 2 * 4;

/// Guest shader pointers captured by the PS4 shader-set imports.
pub const ShaderPrograms = struct {
    pixel: u64 = 0,
    vertex: u64 = 0,
};

// Direct SET_*_REG opcodes and the size of the matching shared register file.
const opcode_set_config_reg: u8 = 0x68;
const opcode_set_context_reg: u8 = 0x69;
const opcode_set_context_reg_index: u8 = 0x6a;
const opcode_set_sh_reg: u8 = 0x76;
const opcode_set_sh_reg_offset: u8 = 0x77;
const opcode_set_uconfig_reg: u8 = 0x79;
const opcode_set_uconfig_reg_index: u8 = 0x7a;

/// Number of entries in the matching shared register file, or null when the
/// opcode is not a direct SET_*_REG write.
fn registerFileCount(opcode: u8) ?u32 {
    return switch (opcode) {
        opcode_set_config_reg => 0x0c00,
        opcode_set_context_reg, opcode_set_context_reg_index => 0x0400,
        opcode_set_sh_reg, opcode_set_sh_reg_offset => 0x0300,
        opcode_set_uconfig_reg, opcode_set_uconfig_reg_index => 0x4000,
        else => null,
    };
}

/// Documented PM4 commands the shared executor can decode. Unknown opcodes are
/// skipped rather than forwarded: an invented packet is worse than a dropped
/// one, and the shared walker would reject the unknown opcode anyway.
fn isKnownOpcode(opcode: u8) bool {
    return switch (opcode) {
        0x10, 0x11, 0x12, 0x13, 0x15, 0x16, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2a, 0x2c, 0x2d, 0x2f, 0x30, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x50, 0x51, 0x57, 0x58, 0x59, 0x5e, 0x5f, 0x60, 0x61, 0x63, 0x64, 0x68, 0x69, 0x6a, 0x76, 0x77, 0x79, 0x7a, 0x80, 0x81, 0x83, 0x84, 0x85, 0x86, 0x8e, 0x9b, 0x9f => true,
        else => false,
    };
}

/// Emit one SET_CONTEXT_REG packet (offset + single value) into `out`.
fn emitContext(out: []u32, write: *usize, offset: u32, value: u32) void {
    out[write.*] = command(opcode_set_context_reg, 2);
    out[write.* + 1] = offset;
    out[write.* + 2] = value;
    write.* += 3;
}

/// Find the value a guest DCB writes to context register `offset`, if any.
/// GCN writes CB_COLORn_BASE as a single SET_CONTEXT_REG packet.
fn writtenContext(src: []const u32, offset: u32) ?u32 {
    var read: usize = 0;
    while (read + 1 < src.len) : (read += 1) {
        const header = src[read];
        if ((header >> kind_shift) != 3) continue;
        if (@as(u8, @truncate(header >> opcode_shift)) != opcode_set_context_reg) continue;
        const body_len: usize = @as(usize, @intCast((header >> count_shift) & count_mask)) + 1;
        if (read + 1 + body_len > src.len) continue;
        const body = src[read + 1 .. read + 1 + body_len];
        if (body.len >= 2 and (body[0] & 0xffff) == offset) return body[1];
    }
    return null;
}

/// Rebuild the AGC render-target registers a PS4 GCN DCB never writes.
///
/// The shared decoder (gpu/resources.zig decodeColorTarget) needs, per slot:
///   BASE_HIGH 0x390+i, DIM 0x3b0+i, DEPTH/TILE 0x3b8+i.
/// A genuine GCN DCB writes BASE/PITCH/VIEW/INFO/ATTRIB at 0x318+i*15 but
/// carries those three fields elsewhere or leaves them zero, so every draw
/// used to reach the backend as `color 0/0`. Supplying them here — derived
/// from the guest's own registers and the VideoOut extent — lets the shared
/// executor see the target without relaxing any shared code.
///
/// Returns the number of dwords written to `out` (always <= max_synthesized_dwords).
pub fn synthesizeRenderTargetRegs(src: []const u32, out: []u32, dims: Dimensions) usize {
    var write: usize = 0;
    for (0..8) |slot| {
        const base_offset: u32 = 0x318 + @as(u32, @intCast(slot)) * 15;
        if (writtenContext(src, base_offset) == null) continue;

        // BASE_HIGH 0x390+i = 0: PS4 GPU addresses are <= 40 bits, so the
        // guest's 32-bit BASE (shifted <<8 by the decoder) already holds every
        // meaningful bit; bits 40..47 are zero.
        emitContext(out, &write, 0x390 + @as(u32, @intCast(slot)), 0);

        // DIM 0x3b0+i: width in bits 14..27, height in bits 0..13. GCN keeps
        // the extent in a different register block; use the known VideoOut
        // framebuffer size so decodeColorTarget reports a non-degenerate target.
        const attrib2 = ((dims.width - 1) << 14) | (dims.height - 1);
        emitContext(out, &write, 0x3b0 + @as(u32, @intCast(slot)), attrib2);

        // DEPTH/TILE 0x3b8+i = 0: one slice (depth = value+1) and linear tiling,
        // so the guest's PITCH applies directly and no metadata is required.
        emitContext(out, &write, 0x3b8 + @as(u32, @intCast(slot)), 0);
    }
    return write;
}

fn emitShaderProgram(out: []u32, write: *usize, base: u32, address: u64) void {
    // programAddress() reconstructs (low << 8) | ((high & 0xff) << 40); store
    // bits 8..39 in the low word and bits 40..47 in the high word.
    const low: u32 = @truncate(address >> 8);
    const high: u32 = @as(u32, @truncate(address >> 40)) & 0xff;
    out[write.*] = command(opcode_set_sh_reg, 3);
    out[write.* + 1] = base;
    out[write.* + 2] = low;
    out[write.* + 3] = high;
    write.* += 4;
}

/// Emit the SH program-address packets the PS4 GNM driver would have written
/// when the title called `sceGnmSetPsShader` / `sceGnmSetVsShader`. The shared
/// decoder reads PS at 0x008/0x009 and VS at 0x048/0x049.
pub fn synthesizeShaderProgramRegs(programs: ShaderPrograms, out: []u32) usize {
    var write: usize = 0;
    if (programs.pixel != 0) emitShaderProgram(out, &write, 0x008, programs.pixel);
    if (programs.vertex != 0) emitShaderProgram(out, &write, 0x048, programs.vertex);
    return write;
}

fn accountDrop(stats: *Stats, opcode: u8) void {
    switch (opcode) {
        opcode_set_config_reg => stats.dropped_config += 1,
        opcode_set_context_reg, opcode_set_context_reg_index => stats.dropped_context += 1,
        opcode_set_sh_reg, opcode_set_sh_reg_offset => stats.dropped_shader += 1,
        opcode_set_uconfig_reg, opcode_set_uconfig_reg_index => stats.dropped_uconfig += 1,
        else => {},
    }
}

/// Rebuilds a walkable PM4 stream from `src` into `dst`, dropping out-of-range
/// direct register writes and non-packet words. Returns dwords written to `dst`.
///
/// Resynchronisation: when a packet is dropped we advance one word, not its
/// whole body. GCN packets often carry a following header where RDNA2 expects
/// a body value (the captured Terraria DCB does exactly this at word 13/14);
/// rescanning the body recovers that header and the draws behind it.
pub fn sanitize(src: []const u32, dst: []u32, stats: *Stats) usize {
    var read: usize = 0;
    var write: usize = 0;
    while (read < src.len) {
        const header = src[read];
        const kind: u2 = @truncate(header >> kind_shift);
        var keep = false;
        var total: usize = 1;

        if (kind == 3) {
            const opcode: u8 = @truncate(header >> opcode_shift);
            const body_len: usize = @as(usize, @intCast((header >> count_shift) & count_mask)) + 1;
            if (isKnownOpcode(opcode) and read + 1 + body_len <= src.len) {
                total = 1 + body_len;
                const body = src[read + 1 .. read + total];
                keep = true;
                if (registerFileCount(opcode)) |count| {
                    if (body.len != 0) {
                        // The offset is a dword index into the shared register
                        // file. A GCN offset past that file cannot be written;
                        // drop the packet so the queue keeps running.
                        const first = body[0] & 0xffff;
                        if (first + @as(u32, @intCast(body.len - 1)) > count) {
                            keep = false;
                            accountDrop(stats, opcode);
                            total = 1; // rescan the body for a valid header
                        }
                    }
                }
            }
        }

        if (keep) {
            if (write + total > dst.len) break;
            @memcpy(dst[write .. write + total], src[read .. read + total]);
            write += total;
            stats.kept += 1;
        } else {
            stats.skipped_words += 1;
        }
        read += total;
    }
    return write;
}

// ---------------------------------------------------------------------------
// Tests — real dwords from Terraria's captured 790-word setup DCB.

fn command(opcode: u8, body_words: usize) u32 {
    return (@as(u32, 3) << 30) | (@as(u32, @intCast(body_words - 1)) << count_shift) | (@as(u32, opcode) << opcode_shift);
}

test "recovers draw behind an out-of-range GCN register packet" {
    // Capture words 7..16: two in-range context writes, one out-of-range
    // header whose first body word is itself the next real header, then a draw.
    const src = [_]u32{
        command(0x69, 2), 0x0205, 0x0246, // word 7: in-range context write
        command(0x69, 2), 0x02df, 0x0000, // word 10: in-range context write
        command(0x69, 2), 0xc0066900, 0x0318, // word 13: bad context write; body[0] is a real header
        command(0x69, 7), 0x0318, 0x10100a00, 0x09f0009f, 0x3bff, 0, 0x28828, 0x14a, // word 14
        command(0x2d, 2), 0x0004, 0x0002, // word 22: DRAW_INDEX_AUTO count=4
    };
    var dst: [64]u32 = undefined;
    var stats: Stats = .{};
    const n = sanitize(&src, &dst, &stats);
    // All four real packets survive (the bad header is dropped, its body is
    // rescanned and the header at word 14 is recovered).
    try std.testing.expectEqual(@as(usize, 4), stats.kept);
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_context);
    // The recovered stream ends with the draw, byte-for-byte.
    try std.testing.expectEqual(@as(u32, command(0x2d, 2)), dst[n - 3]);
    try std.testing.expectEqual(@as(u32, 4), dst[n - 2]);
    try std.testing.expectEqual(@as(u32, 2), dst[n - 1]);
}

test "drops out-of-range shader and config writes, keeps valid ones" {
    const src = [_]u32{
        command(0x76, 2), 0x0300, 0xaaaa, // SET_SH_REG offset 0x300 == file size -> drop
        command(0x76, 2), 0x02ff, 0xbbbb, // SET_SH_REG offset 0x2ff -> keep
        command(0x68, 3), 0x0c00, 1, 2, // SET_CONFIG_REG offset 0xc00 == file size -> drop
        command(0x68, 2), 0x0bff, 3, // SET_CONFIG_REG offset 0xbff -> keep
    };
    var dst: [64]u32 = undefined;
    var stats: Stats = .{};
    const n = sanitize(&src, &dst, &stats);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(usize, 2), stats.kept);
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_shader);
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_config);
    try std.testing.expectEqual(@as(u32, 0x02ff), dst[1]);
}

test "synthesizes missing PS4 render-target registers from the guest's CB base" {
    // A GCN DCB writes BASE/PITCH/VIEW/INFO/ATTRIB at 0x318+i*15 but never the
    // AGC register file's BASE_HIGH/DIM/DEPTH fields.
    const src = [_]u32{
        command(0x69, 7),
        0x0318,
        0x10100a00,
        0x09f0009f,
        0x3bff,
        0,
        0x28828,
        0x14a,
    };
    var out: [max_synthesized_dwords]u32 = undefined;
    const dims = Dimensions{ .width = 64, .height = 32 };
    const n = synthesizeRenderTargetRegs(&src, &out, dims);
    try std.testing.expectEqual(@as(usize, 9), n); // 3 packets × 3 dwords, one slot
    // BASE_HIGH 0x390 = 0.
    try std.testing.expectEqual(@as(u32, command(0x69, 2)), out[0]);
    try std.testing.expectEqual(@as(u32, 0x390), out[1]);
    try std.testing.expectEqual(@as(u32, 0), out[2]);
    // DIM 0x3b0: height in bits 0..13, width in bits 14..27.
    try std.testing.expectEqual(@as(u32, 0x3b0), out[4]);
    try std.testing.expectEqual(@as(u32, ((64 - 1) << 14) | (32 - 1)), out[5]);
    // DEPTH/TILE 0x3b8 = 0 (one slice, linear).
    try std.testing.expectEqual(@as(u32, 0x3b8), out[7]);
    try std.testing.expectEqual(@as(u32, 0), out[8]);
}

test "synthesizes PS/VS program registers from recorded PS4 shader pointers" {
    var out: [max_shader_reg_dwords]u32 = undefined;
    const pair = ShaderPrograms{ .pixel = 0xab12_3456_0000, .vertex = 0x789a_bc00 };
    const n = synthesizeShaderProgramRegs(pair, &out);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(@as(u32, command(0x76, 3)), out[0]);
    try std.testing.expectEqual(@as(u32, 0x008), out[1]);
    try std.testing.expectEqual(@as(u32, 0x1234_5600), out[2]);
    try std.testing.expectEqual(@as(u32, 0xab), out[3]);
    try std.testing.expectEqual(@as(u32, command(0x76, 3)), out[4]);
    try std.testing.expectEqual(@as(u32, 0x048), out[5]);
    try std.testing.expectEqual(@as(u32, 0x78_9abc), out[6]);
    try std.testing.expectEqual(@as(u32, 0), out[7]);
}

test "no recorded shader programs injects nothing into a native stream" {
    var out: [max_shader_reg_dwords]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), synthesizeShaderProgramRegs(.{}, &out));
}

test "no CB base in the stream means no synthesized registers" {
    const src = [_]u32{
        command(0x69, 2), 0x0205, 0x1111,
        command(0x2d, 2), 0x0004, 0x0002,
    };
    var out: [max_synthesized_dwords]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), synthesizeRenderTargetRegs(&src, &out, .{}));
}

test "skips garbage, reserved and truncated words without forwarding them" {
    const src = [_]u32{
        command(0x69, 2), 0x0205, 0x1111, // valid
        0x4000_0000, // type 1 reserved
        0x0000_0000, // bare data word
        command(0x69, 2), 0x0206, 0x2222, // valid again after resync
        command(0x69, 2), 0x0207, // truncated tail
    };
    var dst: [64]u32 = undefined;
    var stats: Stats = .{};
    const n = sanitize(&src, &dst, &stats);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(usize, 2), stats.kept);
    try std.testing.expectEqual(@as(usize, 4), stats.skipped_words);
    try std.testing.expectEqual(@as(u32, 0x0206), dst[4]);
}
