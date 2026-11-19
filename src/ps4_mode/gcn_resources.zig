// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 (GCN) shader resource capture — PS4-only, data only.
//!
//! A GNM driver hands resources to a GCN shader as USER_DATA SGPRs written by
//! PM4 SET_SH_REG (opcode 0x76) packets. Each entry is either a 64-bit pointer
//! pair, a 4-dword V# (constant/vertex buffer), an 8-dword T# (sampled image)
//! or a 4-dword S# (sampler). This module walks a DCB, keeps the final
//! USER_DATA window per stage and emits typed bindings for a future
//! GCN→SPIR-V translator. It deliberately does not touch the shared backend,
//! SHADER program registers, or any renderer state.

const std = @import("std");
const image_layout = @import("image_layout.zig");

/// PM4 fields (kept local so this module stays dependency-free).
const kind_shift: u5 = 30;
const count_shift: u5 = 16;
const count_mask: u32 = 0x3fff;
const opcode_shift: u5 = 8;

const opcode_set_context_reg: u8 = 0x69;
const opcode_set_sh_reg: u8 = 0x76;
const opcode_set_uconfig_reg: u8 = 0x79;
const opcode_draw_index_auto: u8 = 0x2d;

/// USER_DATA is a row of 16 SGPRs per stage. Bases match gpu.ShaderStage.
pub const user_data_words: usize = 16;
/// Chronological trace cap; the real Terraria DCB produces 13 bindings.
pub const max_bindings: usize = 64;

pub const Stage = enum {
    pixel,
    vertex,
    compute,

    pub fn userDataBase(self: Stage) u32 {
        return switch (self) {
            .pixel => 0x00c,
            .vertex => 0x04c,
            .compute => 0x240,
        };
    }

    pub fn name(self: Stage) []const u8 {
        return switch (self) {
            .pixel => "PS",
            .vertex => "VS",
            .compute => "CS",
        };
    }
};

pub const ResourceKind = enum {
    /// 64-bit pointer pair; the translator decides what it points at.
    raw_address,
    /// V# / buffer resource: base, stride, num records.
    constant_buffer,
    /// T# / image resource: base, extent, format, tiling.
    sampled_image,
    /// S# / sampler resource: filtering state, no GPU address.
    sampler,
};

/// One decoded descriptor. `address` is the 40-bit GPU base (0 for samplers).
pub const Descriptor = struct {
    kind: ResourceKind,
    address: u64 = 0,
    size_bytes: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    data_format: u8 = 0,
    num_format: u8 = 0,
    tiling_index: u8 = 0,
    tiling: image_layout.Tiling = .linear,
};

/// A USER_DATA binding with its register provenance, ready for translation.
pub const Binding = struct {
    stage: Stage,
    /// First SH register offset written by the guest packet (e.g. 0x010).
    register: u32,
    /// Index inside the stage's 16-word USER_DATA row (0..15).
    user_data_index: u8,
    descriptor: Descriptor,
};

/// Result of `capture`. Fixed capacity, no allocator.
pub const Resources = struct {
    /// Chronological descriptor trace, in DCB order (duplicates included).
    bindings: [max_bindings]Binding = undefined,
    count: usize = 0,
    /// Descriptors that did not fit in `bindings`.
    overflow: usize = 0,

    /// Final settled USER_DATA rows (what the shader actually observes).
    pixel_user_data: [user_data_words]u32 = @splat(0),
    vertex_user_data: [user_data_words]u32 = @splat(0),
    compute_user_data: [user_data_words]u32 = @splat(0),
    pixel_written: [user_data_words]bool = @splat(false),
    vertex_written: [user_data_words]bool = @splat(false),
    compute_written: [user_data_words]bool = @splat(false),

    /// Packet counts, so callers can see what the DCB actually contained.
    sh_reg_packets: usize = 0,
    uconfig_reg_packets: usize = 0,
    context_reg_packets: usize = 0,

    pub fn userData(self: *const Resources, stage: Stage) []const u32 {
        return switch (stage) {
            .pixel => &self.pixel_user_data,
            .vertex => &self.vertex_user_data,
            .compute => &self.compute_user_data,
        };
    }

    pub fn wasWritten(self: *const Resources, stage: Stage, index: usize) bool {
        if (index >= user_data_words) return false;
        return switch (stage) {
            .pixel => self.pixel_written[index],
            .vertex => self.vertex_written[index],
            .compute => self.compute_written[index],
        };
    }

    /// Descriptor words for a binding (T#/V#/S# up to 8 dwords).
    pub fn words(self: *const Resources, binding: Binding) [8]u32 {
        var out: [8]u32 = @splat(0);
        const row = self.userData(binding.stage);
        const start = binding.user_data_index;
        const n: usize = switch (binding.descriptor.kind) {
            .sampled_image => 8,
            .constant_buffer, .sampler => 4,
            .raw_address => 2,
        };
        for (0..n) |k| {
            if (start + k < user_data_words) out[k] = row[start + k];
        }
        return out;
    }
};

/// The VS/PS program pair a submit binds. Defined here (rather than in a later
/// task) so every consumer shares one definition.
pub const ProgramPair = struct { vertex: u64 = 0, pixel: u64 = 0 };

pub const max_draws_per_capture: usize = 8;
pub const max_capture_queue: usize = 8;

/// Ordered snapshots of `Resources`, one per DRAW_INDEX_AUTO in a DCB. A DCB
/// with no draw packets keeps its whole-stream result in `draws[0]`.
pub const Capture = struct {
    draws: [max_draws_per_capture]Resources = undefined,
    count: usize = 0,
};

/// PS4-only submit-boundary capture. `publish` appends a DCB's ordered draw
/// snapshots to a FIFO; `nextDrawResources` drains them in submit/draw order.
/// A mutex and value copies keep this safe for the multi-threaded command queue.
var captured_lock: std.atomic.Mutex = .unlocked;
var capture_queue: [max_capture_queue]Capture = undefined;
var capture_head: usize = 0;
var capture_len: usize = 0;
var capture_draw_cursor: usize = 0;

/// Publish one submitted DCB's ordered per-draw snapshots. PS4 submit boundary.
pub fn publish(cap: Capture) void {
    while (!captured_lock.tryLock()) std.atomic.spinLoopHint();
    defer captured_lock.unlock();
    if (capture_len == capture_queue.len) {
        // Ring full: drop the oldest capture and its draw cursor.
        capture_head = (capture_head + 1) % capture_queue.len;
        capture_len -= 1;
        capture_draw_cursor = 0;
    }
    const tail = (capture_head + capture_len) % capture_queue.len;
    capture_queue[tail] = cap;
    capture_len += 1;
}

/// Consume the next draw snapshot in submit/draw order. Exhausted captures are
/// dropped while a newer one exists; a final capture with more draws than
/// snapshots clamps to its last snapshot. Null means nothing was published.
pub fn nextDrawResources() ?Resources {
    while (!captured_lock.tryLock()) std.atomic.spinLoopHint();
    defer captured_lock.unlock();
    if (capture_len == 0) return null;
    while (capture_len > 1 and capture_draw_cursor >= capture_queue[capture_head].count) {
        capture_head = (capture_head + 1) % capture_queue.len;
        capture_len -= 1;
        capture_draw_cursor = 0;
    }
    const current = &capture_queue[capture_head];
    if (current.count == 0) return null;
    if (capture_draw_cursor < current.count) {
        const out = current.draws[capture_draw_cursor];
        capture_draw_cursor += 1;
        return out;
    }
    return current.draws[current.count - 1];
}

/// Clear captured state (PS4 session reset / tests).
pub fn resetCapture() void {
    while (!captured_lock.tryLock()) std.atomic.spinLoopHint();
    defer captured_lock.unlock();
    capture_queue = undefined;
    capture_head = 0;
    capture_len = 0;
    capture_draw_cursor = 0;
}

/// GCN T# tiling_index → the only four layouts image_layout.zig models.
fn mapTiling(index: u8) image_layout.Tiling {
    return switch (index) {
        8, 9, 10, 11, 12, 31 => .display, // display-linear / display-thin
        19, 20, 21, 22, 23, 24, 25, 26 => .thick_1d,
        0...7, 13...18 => .thin_1d,
        else => .linear,
    };
}

fn bytesPerTexel(data_format: u8) u32 {
    // GCN BUF_DATA_FORMAT: 1=8, 3=8_8, 10=8_8_8_8, 4=32, 5=16_16, 14=16_16_16_16.
    return switch (data_format) {
        1 => 1,
        2, 3 => 2,
        4, 8, 9, 10, 11, 12, 13, 16, 17 => 4,
        5, 6, 7, 14, 15, 18, 19 => 8,
        else => 4,
    };
}

/// Interpret four dwords as a GCN V# (buffer resource).
///
/// word0 = base[31:0], word1 bits 11:0 = base[43:32], bits 29:16 = stride,
/// word2 = num records, word3 bits 31:30 = type (0 for a buffer).
pub fn formatV(words: []const u32) ?Descriptor {
    if (words.len < 4) return null;
    const base = @as(u64, words[0]) | (@as(u64, words[1] & 0xfff) << 32);
    const stride: u32 = (words[1] >> 16) & 0x3fff;
    const record_count = words[2];
    const kind_bits: u32 = words[3] >> 30;
    // A null/implausible base or a non-buffer type is not a V#; callers fall
    // back to sampler interpretation for four-dword USER_DATA entries.
    if (base < 0x1000 or kind_bits != 0) return null;
    return .{
        .kind = .constant_buffer,
        .address = base,
        .size_bytes = if (stride == 0) record_count else @as(u64, stride) * record_count,
    };
}

/// Interpret up to eight dwords as a GCN T# (image resource).
///
/// base_address occupies word0 + word1 bits 5:0 and is shifted left 8 by the
/// hardware (256-byte aligned). Extent/format/type live in word2/word3.
pub fn formatT(words: []const u32) ?Descriptor {
    if (words.len < 8) return null;
    const base = (@as(u64, words[0]) | (@as(u64, words[1] & 0x3f) << 32)) << 8;
    const texture_type: u8 = @truncate((words[3] >> 28) & 0xf);
    // GCN type 8..15 is a texture (1D/2D/3D/cube/array/msaa); 0 is a buffer.
    if (base == 0 or texture_type < 8) return null;

    const data_format: u8 = @truncate((words[1] >> 20) & 0x3f);
    const num_format: u8 = @truncate((words[1] >> 26) & 0xf);
    const width: u32 = (words[2] & 0x3fff) + 1;
    const height: u32 = ((words[2] >> 14) & 0x3fff) + 1;
    const tiling_index: u8 = @truncate((words[3] >> 20) & 0x1f);
    const pitch: u32 = ((words[4] >> 13) & 0x3fff) + 1;
    const tiling = mapTiling(tiling_index);
    const bpp = bytesPerTexel(data_format);
    return .{
        .kind = .sampled_image,
        .address = base,
        .width = width,
        .height = height,
        .pitch = if (pitch > 1 and image_layout.pitchValid(pitch, width, bpp, tiling)) pitch else image_layout.derivePitch(width, bpp, tiling),
        .data_format = data_format,
        .num_format = num_format,
        .tiling_index = tiling_index,
        .tiling = tiling,
    };
}

/// Interpret four dwords as a GCN S# (sampler). Samplers carry no GPU address.
pub fn formatS(words: []const u32) ?Descriptor {
    if (words.len < 4) return null;
    if (words[0] == 0 and words[1] == 0 and words[2] == 0 and words[3] == 0) return null;
    return .{ .kind = .sampler };
}

/// Interpret a 64-bit USER_DATA pointer pair (low, high dwords).
pub fn formatPointer(low: u32, high: u32) Descriptor {
    return .{
        .kind = .raw_address,
        .address = @as(u64, low) | (@as(u64, high & 0xfff) << 32),
    };
}

/// Dispatch a captured USER_DATA block to the right descriptor decoder.
/// Classification is by dword count and descriptor validity, which matches
/// how GNM emits each resource as one contiguous SET_SH_REG packet.
pub fn format(words: []const u32) ?Descriptor {
    return switch (words.len) {
        2 => formatPointer(words[0], words[1]),
        4 => formatV(words) orelse formatS(words),
        8 => formatT(words) orelse (formatV(words[0..4]) orelse formatS(words[0..4])),
        else => null,
    };
}

fn append(res: *Resources, stage: Stage, register: u32, index: u8, descriptor: Descriptor) void {
    if (res.count >= res.bindings.len) {
        res.overflow += 1;
        return;
    }
    res.bindings[res.count] = .{
        .stage = stage,
        .register = register,
        .user_data_index = index,
        .descriptor = descriptor,
    };
    res.count += 1;
}

fn settledRow(res: *Resources, stage: Stage) *[user_data_words]u32 {
    return switch (stage) {
        .pixel => &res.pixel_user_data,
        .vertex => &res.vertex_user_data,
        .compute => &res.compute_user_data,
    };
}

fn settledFlags(res: *Resources, stage: Stage) *[user_data_words]bool {
    return switch (stage) {
        .pixel => &res.pixel_written,
        .vertex => &res.vertex_written,
        .compute => &res.compute_written,
    };
}

fn stageForRegister(register: u32) ?Stage {
    inline for (.{ Stage.pixel, Stage.vertex, Stage.compute }) |stage| {
        const base = stage.userDataBase();
        if (register >= base and register < base + user_data_words) return stage;
    }
    return null;
}

/// Copy the running `Resources` into a draw snapshot, up to capacity.
fn snapshotDraw(cap: *Capture, res: *const Resources) void {
    if (cap.count >= cap.draws.len) return;
    cap.draws[cap.count] = res.*;
    cap.count += 1;
}

/// Walk a GCN DCB and capture ordered per-draw shader resource snapshots.
/// `words` is the raw guest stream (sanitized or not — SET_SH_REG packets are
/// in range for both). The running `Resources` is copied at each
/// DRAW_INDEX_AUTO; a DCB with no draws keeps its whole-stream result in
/// `draws[0]`.
pub fn capture(words: []const u32) Capture {
    var res = Resources{};
    var cap = Capture{};
    var read: usize = 0;
    while (read < words.len) {
        const header = words[read];
        if ((header >> kind_shift) != 3) {
            read += 1;
            continue;
        }
        const opcode: u8 = @truncate(header >> opcode_shift);
        const body_len: usize = @as(usize, @intCast((header >> count_shift) & count_mask)) + 1;
        if (read + 1 + body_len > words.len) {
            read += 1;
            continue;
        }
        const body = words[read + 1 .. read + 1 + body_len];

        switch (opcode) {
            opcode_set_context_reg => res.context_reg_packets += 1,
            opcode_set_uconfig_reg => res.uconfig_reg_packets += 1,
            opcode_set_sh_reg => {
                res.sh_reg_packets += 1;
                if (body.len == 0) {
                    read += 1 + body_len;
                    continue;
                }
                const register = body[0] & 0xffff;
                const values = body[1..];

                // Always update the settled USER_DATA row, including writes
                // that only partially overlap a stage window.
                for (values, 0..) |value, k| {
                    const reg = register + @as(u32, @intCast(k));
                    if (stageForRegister(reg)) |stage| {
                        const index: usize = reg - stage.userDataBase();
                        settledRow(&res, stage)[index] = value;
                        settledFlags(&res, stage)[index] = true;
                    }
                }

                // Classify only packets wholly inside one stage's row: GNM
                // writes a whole V#/T#/S#/pointer in a single packet.
                if (stageForRegister(register)) |stage| {
                    if (register + values.len <= stage.userDataBase() + user_data_words) {
                        if (format(values)) |descriptor| {
                            append(&res, stage, register, @intCast(register - stage.userDataBase()), descriptor);
                        }
                    }
                }
            },
            opcode_draw_index_auto => snapshotDraw(&cap, &res),
            else => {},
        }
        read += 1 + body_len;
    }
    if (cap.count == 0) snapshotDraw(&cap, &res);
    return cap;
}

// ---------------------------------------------------------------------------
// Tests — driven by Terraria's real captured DCB.
// ---------------------------------------------------------------------------

const fixture = @import("terraria_frame_test.zig");
const dcb = &fixture.captured_dcb;

fn hasBinding(res: *const Resources, stage: Stage, register: u32, kind: ResourceKind, address: u64) bool {
    for (res.bindings[0..res.count]) |b| {
        if (b.stage == stage and b.register == register and
            b.descriptor.kind == kind and b.descriptor.address == address) return true;
    }
    return false;
}

test "Terraria DCB: recover PS/VS/CS USER_DATA descriptors from real SET_SH_REG packets" {
    // Sanity: the fixture is the exact 790-dword capture, not a trimmed slice.
    try std.testing.expectEqual(@as(usize, 790), dcb.len);
    try std.testing.expectEqual(@as(u32, 0xc005_5800), dcb[0]);

    const captures = capture(dcb);
    const res = &captures.draws[captures.count - 1]; // final settled draw

    // The DCB really contains SH/UCONFIG/CONTEXT packets; resources come from
    // SH, the other two are counted only for the register dump.
    try std.testing.expectEqual(@as(usize, 13), res.sh_reg_packets);
    try std.testing.expectEqual(@as(usize, 2), res.uconfig_reg_packets);
    try std.testing.expect(res.context_reg_packets > 0);

    // Every classified packet landed inside a stage USER_DATA row.
    try std.testing.expectEqual(@as(usize, 13), res.count);
    try std.testing.expectEqual(@as(usize, 0), res.overflow);

    // Compute (0x244/0x248/0x24c): three V# buffers, including one that views
    // the 1920x1080 colour target at base 0x10_168c8000.
    try std.testing.expect(hasBinding(res, .compute, 0x248, .constant_buffer, 0x10_168c8000));
    try std.testing.expect(hasBinding(res, .compute, 0x244, .constant_buffer, 0x10_00000704));
    try std.testing.expect(hasBinding(res, .compute, 0x24c, .constant_buffer, 0x10_0000074c));

    // Vertex (0x4c/0x4e/0x54): two 64-bit raw pointers and one 16-byte-stride
    // constant buffer (4 records = 64 bytes) in each of the two draw blocks.
    try std.testing.expect(hasBinding(res, .vertex, 0x4c, .raw_address, 0x10_1009cbb0));
    try std.testing.expect(hasBinding(res, .vertex, 0x4e, .raw_address, 0x10_10000f5c));
    try std.testing.expect(hasBinding(res, .vertex, 0x4e, .raw_address, 0x10_10000f8c));
    try std.testing.expect(hasBinding(res, .vertex, 0x54, .constant_buffer, 0x10_1009cb60));
    try std.testing.expect(hasBinding(res, .vertex, 0x54, .constant_buffer, 0x10_1009d0a4));

    // Pixel (0x10/0x18): a 4-dword S# sampler and an 8-dword T# image. The
    // second T# is the guest colour target decoded as 1920x1080 RGBA8.
    try std.testing.expect(hasBinding(res, .pixel, 0x18, .sampler, 0));
    try std.testing.expect(hasBinding(res, .pixel, 0x10, .sampled_image, 0x10_170c0000));
    try std.testing.expect(hasBinding(res, .pixel, 0x10, .sampled_image, 0x10_168c8000));

    // Settled USER_DATA row contains the last values written (second draw).
    try std.testing.expectEqual(@as(u32, 0x10168c80), res.pixel_user_data[4]);
    try std.testing.expectEqual(@as(u32, 0x10dc77f), res.pixel_user_data[6]);
    try std.testing.expect(res.wasWritten(.pixel, 12));
    try std.testing.expect(!res.wasWritten(.pixel, 0));
    try std.testing.expectEqual(@as(u32, 0x1009d0a4), res.vertex_user_data[8]);
    try std.testing.expectEqual(@as(u32, 0x10000f8c), res.vertex_user_data[2]);
    try std.testing.expect(!res.wasWritten(.vertex, 4));
    try std.testing.expectEqual(@as(u32, 0x168c8000), res.compute_user_data[8]);
}

test "format helpers decode GCN V#/T#/S#/pointer descriptors" {
    // V#: 16-byte stride, 4 records, base 0x10_1009cb60.
    const v = formatV(&.{ 0x1009cb60, 0x100010, 4, 0x20077fac }).?;
    try std.testing.expectEqual(ResourceKind.constant_buffer, v.kind);
    try std.testing.expectEqual(@as(u64, 0x10_1009cb60), v.address);
    try std.testing.expectEqual(@as(u64, 64), v.size_bytes);

    // T#: 1920x1080 RGBA8, base 0x10_168c8000, display-thin tiling (index 10).
    const t = formatT(&.{ 0x10168c80, 0xa00000, 0x10dc77f, 0x94a00fac, 0xefe000, 0, 0, 0 }).?;
    try std.testing.expectEqual(ResourceKind.sampled_image, t.kind);
    try std.testing.expectEqual(@as(u64, 0x10_168c8000), t.address);
    try std.testing.expectEqual(@as(u32, 1920), t.width);
    try std.testing.expectEqual(@as(u32, 1080), t.height);
    try std.testing.expectEqual(@as(u8, 10), t.data_format);
    try std.testing.expectEqual(@as(u8, 0), t.num_format);
    try std.testing.expectEqual(image_layout.Tiling.display, t.tiling);

    // S#: filtering state, no address. A plausible V# is preferred over S#.
    const s = format(&.{ 0x92, 0xfff000, 0x9500000, 0 }).?;
    try std.testing.expectEqual(ResourceKind.sampler, s.kind);
    try std.testing.expectEqual(@as(u64, 0), s.address);
    try std.testing.expectEqual(null, formatS(&.{ 0, 0, 0, 0 }));

    const p = format(&.{ 0x1009cbb0, 0x10 }).?;
    try std.testing.expectEqual(ResourceKind.raw_address, p.kind);
    try std.testing.expectEqual(@as(u64, 0x10_1009cbb0), p.address);
    try std.testing.expectEqual(null, format(&.{ 0x1, 0x2, 0x3 }));
}

test "publish/nextDrawResources/reset drain DCB snapshots at the submit boundary" {
    resetCapture();
    defer resetCapture();
    try std.testing.expect(nextDrawResources() == null);

    publish(capture(dcb));
    // The real DCB has two DRAW_INDEX_AUTO packets: first sprite T#, then the
    // colour target. The FIFO returns them in submit/draw order.
    const first = nextDrawResources() orelse return error.TestExpectedResources;
    try std.testing.expect(hasBinding(&first, .pixel, 0x10, .sampled_image, 0x10_170c0000));
    const got = nextDrawResources() orelse return error.TestExpectedResources;
    try std.testing.expectEqual(@as(usize, 13), got.count);
    try std.testing.expectEqual(@as(u32, 0x10168c80), got.pixel_user_data[4]);
    try std.testing.expect(hasBinding(&got, .pixel, 0x10, .sampled_image, 0x10_168c8000));

    resetCapture();
    try std.testing.expect(nextDrawResources() == null);
}

test "capture ignores SH packets outside USER_DATA rows and malformed packets" {
    const words = [_]u32{
        // SET_SH_REG 0x100 (outside all rows) — counted, not a binding.
        (@as(u32, 3) << 30) | (@as(u32, 2) << 16) | (@as(u32, 0x76) << 8),
        0x100,
        0xdeadbeef,
        // Truncated SET_SH_REG — skipped.
        (@as(u32, 3) << 30) | (@as(u32, 8) << 16) | (@as(u32, 0x76) << 8),
        0x4c,
        // Real raw pointer in the vertex row.
        (@as(u32, 3) << 30) | (@as(u32, 2) << 16) | (@as(u32, 0x76) << 8),
        0x4c,
        0x1009cbb0,
        0x10,
    };
    const captures = capture(&words);
    const res = &captures.draws[0]; // no DRAW_INDEX_AUTO: whole-stream result
    try std.testing.expectEqual(@as(usize, 2), res.sh_reg_packets);
    try std.testing.expectEqual(@as(usize, 1), res.count);
    try std.testing.expectEqual(ResourceKind.raw_address, res.bindings[0].descriptor.kind);
    try std.testing.expectEqual(@as(u64, 0x10_1009cbb0), res.bindings[0].descriptor.address);
}

// --- Ordered per-draw capture fixtures (real dwords from terraria_frame_test.zig) ---

// PS T# SET_SH_REG (0x10..0x17) with the guest sprite texture at 0x10170c0000.
const sh_t_a = [_]u32{
    0xc0087600, 0x00000010, 0x10170c00, 0x00a00000,
    0x0077c2ab, 0x94d00f2e, 0x0055e000, 0x00000000,
    0x00000000, 0x00000000,
};
// Same register window rebound to the 1920x1080 colour target at 0x10168c8000.
const sh_t_b = [_]u32{
    0xc0087600, 0x00000010, 0x10168c80, 0x00a00000,
    0x010dc77f, 0x94a00fac, 0x00efe000, 0x00000000,
    0x00000000, 0x00000000,
};
const draw_auto = [_]u32{ 0xc0012d00, 0x00000004, 0x00000002 };

const dcb_a = sh_t_a ++ draw_auto;
const dcb_b = sh_t_b ++ draw_auto;
const dcb_with_two_draws = sh_t_a ++ draw_auto ++ sh_t_b ++ draw_auto;

fn psImage(res: Resources) ?Descriptor {
    var out: ?Descriptor = null;
    for (res.bindings[0..res.count]) |binding| {
        if (binding.stage == .pixel and binding.descriptor.kind == .sampled_image)
            out = binding.descriptor; // last PS T# write settles the texture
    }
    return out;
}

test "per-draw snapshots keep distinct PS textures" {
    resetCapture();
    defer resetCapture();
    publish(capture(&dcb_a)); // PS T# 0x10170c0000
    publish(capture(&dcb_b)); // PS T# 0x10168c8000
    const a = nextDrawResources().?;
    const b = nextDrawResources().?;
    try std.testing.expectEqual(@as(u64, 0x10170c0000), psImage(a).?.address);
    try std.testing.expectEqual(@as(u64, 0x10168c8000), psImage(b).?.address);
}

test "capture FIFO is ordered for equal program pairs" {
    resetCapture();
    defer resetCapture();
    publish(capture(&dcb_with_two_draws)); // snapshots: T# A, T# B
    const first = nextDrawResources().?;
    const second = nextDrawResources().?;
    try std.testing.expectEqual(@as(u64, 0x10170c0000), psImage(first).?.address);
    try std.testing.expectEqual(@as(u64, 0x10168c8000), psImage(second).?.address);
    try std.testing.expect(nextDrawResources() != null); // clamp to last
}
