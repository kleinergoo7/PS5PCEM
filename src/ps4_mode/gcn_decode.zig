// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Correct GCN (GFX6/7) top-level decoder for PS4 shader ISA.
//!
//! `gcn_lower.classify` uses RDNA2-family numbers and misroutes real GCN
//! words; this module is the authoritative front-end. It exposes a tagged
//! `Instruction` stream for inspection and, for translation, re-encodes the
//! few families whose layouts differ (SOP1 opcodes, SMRD length) into the
//! normalized GFX10 words that `rdna2.decodeProgram` already understands.
//! SPIR-V emission stays entirely in `rdna2/spirv.zig`.

const std = @import("std");
const rdna2 = @import("rdna2");

pub const Error = std.mem.Allocator.Error || error{
    TruncatedInstruction,
    UnsupportedInstruction,
};

const Family = enum {
    vop2,
    vopc,
    vop1,
    sop2,
    sopk,
    sop1,
    sopc,
    sopp,
    smrd,
    vintrp,
    vop3,
    ds,
    flat,
    mubuf,
    mtbuf,
    mimg,
    exp,
    unsupported,
};

pub const Tag = enum {
    s_mov_b32,
    s_mov_b64,
    s_endpgm,
    s_branch,
    s_cbranch,
    s_load_dwordx4,
    s_buffer_load_dwordx4,
    v_add_f32,
    v_sub_f32,
    v_subrev_f32,
    v_mul_f32,
    v_min_f32,
    v_max_f32,
    v_mac_f32,
    v_mov_b32,
    v_cmp,
    v_mad_f32,
    v_interp_p1_f32,
    v_interp_p2_f32,
    buffer_load_format_xyzw,
    image_sample,
    exp,
    s_waitcnt,
    unsupported,
};

pub const Base = struct {
    pc: u32 = 0,
    word_count: u32 = 1,
};

pub const Mov = struct {
    base: Base = .{},
    dst: u32 = 0,
    src: u32 = 0,
    immediate: bool = false,
};
pub const Simple = struct { base: Base = .{}, simm: u16 = 0 };
pub const Branch = struct {
    base: Base = .{},
    op: u32 = 0,
    simm: i16 = 0,
    target: u32 = 0,
};
pub const Smem = struct {
    base: Base = .{},
    op: u32 = 0,
    dst: u32 = 0,
    sbase: u32 = 0,
    offset: u32 = 0,
    immediate: bool = false,
};
pub const Vop2 = struct {
    base: Base = .{},
    op: u32 = 0,
    dst: u32 = 0,
    src0: u32 = 0,
    src1: u32 = 0,
    literal: bool = false,
};
pub const Vop1 = struct {
    base: Base = .{},
    op: u32 = 0,
    dst: u32 = 0,
    src0: u32 = 0,
    literal: bool = false,
};
pub const Vopc = struct {
    base: Base = .{},
    op: u32 = 0,
    src0: u32 = 0,
    src1: u32 = 0,
    literal: bool = false,
};
pub const Vop3 = struct {
    base: Base = .{},
    op: u32 = 0,
    dst: u32 = 0,
    src0: u32 = 0,
    src1: u32 = 0,
    src2: u32 = 0,
    literal: bool = false,
};
pub const Vintrp = struct {
    base: Base = .{},
    op: u32 = 0,
    attr: u32 = 0,
    dst: u32 = 0,
    src: u32 = 0,
};
pub const Mubuf = struct {
    base: Base = .{},
    op: u32 = 0,
    dst: u32 = 0,
    vaddr: u32 = 0,
    srsrc: u32 = 0,
    soffset: u32 = 0,
    offset: u32 = 0,
    idxen: bool = false,
    ofen: bool = false,
};
pub const Mimg = struct {
    base: Base = .{},
    op: u32 = 0,
    dmask: u4 = 0,
    dst: u32 = 0,
    addr: u32 = 0,
    tsgpr: u32 = 0,
    ssgpr: u32 = 0,
};
pub const Exp = struct {
    base: Base = .{},
    target: u6 = 0,
    enable: u4 = 0,
    done: bool = false,
    src: [4]u8 = .{ 0, 0, 0, 0 },
};
pub const Unsupported = struct {
    base: Base = .{},
    word: u32 = 0,
    reason: []const u8 = "",
};

pub const Instruction = union(enum) {
    s_mov_b32: Mov,
    s_mov_b64: Mov,
    s_endpgm: Simple,
    s_branch: Branch,
    s_cbranch: Branch,
    s_load_dwordx4: Smem,
    s_buffer_load_dwordx4: Smem,
    v_add_f32: Vop2,
    v_sub_f32: Vop2,
    v_subrev_f32: Vop2,
    v_mul_f32: Vop2,
    v_min_f32: Vop2,
    v_max_f32: Vop2,
    v_mac_f32: Vop2,
    v_mov_b32: Vop1,
    v_cmp: Vopc,
    v_mad_f32: Vop3,
    v_interp_p1_f32: Vintrp,
    v_interp_p2_f32: Vintrp,
    buffer_load_format_xyzw: Mubuf,
    image_sample: Mimg,
    exp: Exp,
    s_waitcnt: Simple,
    unsupported: Unsupported,

    pub fn tag(self: Instruction) Tag {
        // Variants are declared in the same order as Tag.
        return @enumFromInt(@intFromEnum(std.meta.activeTag(self)));
    }

    pub fn base(self: *const Instruction) Base {
        return switch (self.*) {
            inline else => |payload| payload.base,
        };
    }
};

/// GCN family from the architectural encoding bits of word0.
pub fn family(word0: u32) Family {
    if (word0 & 0x8000_0000 == 0) {
        const id: u6 = @intCast((word0 >> 25) & 0x3f);
        return if (id == 0x3e) .vopc else if (id == 0x3f) .vop1 else .vop2;
    }
    if (word0 & 0xc000_0000 == 0x8000_0000) {
        return switch ((word0 >> 23) & 0x7f) {
            0x7d => .sop1,
            0x7e => .sopc,
            0x7f => .sopp,
            else => |op| if (op >= 0x60) .sopk else .sop2,
        };
    }
    return switch ((word0 >> 26) & 0x3f) {
        0x30, 0x31 => .smrd,
        0x32 => .vintrp,
        0x34 => .vop3,
        0x36 => .ds,
        0x37 => .flat,
        0x38 => .mubuf,
        0x3a => .mtbuf,
        0x3c => .mimg,
        0x3e => .exp,
        else => .unsupported,
    };
}

/// Iterator over a raw GCN word stream. Optionally emits normalized GFX10
/// words while stepping, which is how `decodeToRdna2` reuses rdna2's decoders.
pub const Iterator = struct {
    words: []const u32,
    allocator: std.mem.Allocator,
    index: u32 = 0,
    normalized: ?*std.ArrayList(u32) = null,

    fn append(self: *Iterator, word: u32) Error!void {
        if (self.normalized) |list| try list.append(self.allocator, word);
    }

    fn literal(self: *Iterator, word_index: u32, count: *u32) Error!u32 {
        const at = word_index + count.*;
        if (at >= self.words.len) return Error.TruncatedInstruction;
        count.* += 1;
        return self.words[at];
    }

    fn unsupported(self: *Iterator, fam: Family, word: u32, count: u32, reason: []const u8, emit_nops: bool) Error!Instruction {
        // Families with no known length still need placeholder words to keep
        // PCs/branch targets stable. Known families have already emitted their
        // original words before the opcode check.
        if (emit_nops) {
            const nops: u32 = if (fam == .ds or fam == .flat or fam == .mtbuf) 2 else 1;
            for (0..@min(nops, count)) |_| try self.append(0xbf80_0000);
        }
        return .{ .unsupported = .{
            .base = .{ .pc = self.index * 4, .word_count = count },
            .word = word,
            .reason = reason,
        } };
    }

    pub fn next(self: *Iterator) Error!?Instruction {
        if (self.index >= self.words.len) return null;
        const wi = self.index;
        const w0 = self.words[wi];
        const pc: u32 = @intCast(wi * 4);
        var count: u32 = 1;
        const fam = family(w0);
        const result: Instruction = switch (fam) {
            .sop1 => blk: {
                const gcn_op = (w0 >> 8) & 0xff;
                const ssrc0 = w0 & 0xff;
                const dst = (w0 >> 16) & 0x7f;
                const immediate = ssrc0 == 255;
                const literal_value = if (immediate) try self.literal(wi, &count) else 0;
                // GCN SOP1 IDs are shifted relative to RDNA2 for the moves.
                const rdna_op: u32 = switch (gcn_op) {
                    0x00 => 0x03,
                    0x01 => 0x04,
                    else => gcn_op,
                };
                try self.append((w0 & ~@as(u32, 0xff00)) | (rdna_op << 8));
                if (immediate) try self.append(literal_value);
                const base = Base{ .pc = pc, .word_count = count };
                break :blk switch (gcn_op) {
                    0x00 => .{ .s_mov_b32 = .{ .base = base, .dst = dst, .src = ssrc0, .immediate = immediate } },
                    0x01 => .{ .s_mov_b64 = .{ .base = base, .dst = dst, .src = ssrc0, .immediate = immediate } },
                    else => try self.unsupported(fam, w0, count, "unsupported SOP1 opcode", false),
                };
            },
            .sopp => blk: {
                const op = (w0 >> 16) & 0x7f;
                const simm: i16 = @bitCast(@as(u16, @truncate(w0)));
                // s_waitcnt is a sync hint; lower it to s_nop so dword PCs and
                // branch targets stay identical.
                const is_wait = op == 0x0c or (op >= 0x17 and op <= 0x1a);
                const emitted: u32 = if (is_wait) 0xbf80_0000 else w0;
                const base = Base{ .pc = pc, .word_count = count };
                const result: Instruction = switch (op) {
                    0x01 => .{ .s_endpgm = .{ .base = base, .simm = @intCast(w0 & 0xffff) } },
                    0x02 => .{ .s_branch = .{ .base = base, .op = op, .simm = simm, .target = pc +% 4 +% @as(u32, @bitCast(@as(i32, simm) * 4)) } },
                    0x04, 0x05 => .{ .s_cbranch = .{ .base = base, .op = op, .simm = simm, .target = pc +% 4 +% @as(u32, @bitCast(@as(i32, simm) * 4)) } },
                    else => if (is_wait)
                        Instruction{ .s_waitcnt = .{ .base = base, .simm = @intCast(w0 & 0xffff) } }
                    else
                        try self.unsupported(fam, w0, count, "unsupported SOPP opcode", false),
                };
                if (result.tag() != .unsupported) try self.append(emitted);
                break :blk result;
            },
            .smrd => blk: {
                // GCN SMRD: [31:27]=0x18, OP[26:22], SDST[21:15],
                // SBASE[14:9] (SGPR pair / 2), IMM[8], OFFSET[7:0] — one dword.
                const op = (w0 >> 22) & 0x1f;
                const dst = (w0 >> 15) & 0x7f;
                const sbase = (w0 >> 9) & 0x3f;
                const immediate = (w0 >> 8) & 1 != 0;
                const offset = w0 & 0xff;
                // RDNA2 SMEM is two dwords: OP[25:18], SDST[12:6], SBASE[5:0].
                try self.append(0xf400_0000 | (op << 18) | (dst << 6) | sbase);
                try self.append(offset & 0x001f_ffff);
                const base = Base{ .pc = pc, .word_count = count };
                break :blk switch (op) {
                    0x02 => .{ .s_load_dwordx4 = .{ .base = base, .op = op, .dst = dst, .sbase = sbase * 2, .offset = offset, .immediate = immediate } },
                    0x0a => .{ .s_buffer_load_dwordx4 = .{ .base = base, .op = op, .dst = dst, .sbase = sbase * 2, .offset = offset, .immediate = immediate } },
                    else => try self.unsupported(fam, w0, count, "unsupported SMRD opcode", false),
                };
            },
            .vop2, .vopc, .vop1 => blk: {
                const id: u32 = @intCast((w0 >> 25) & 0x3f);
                const src0 = w0 & 0x1ff;
                const immediate = src0 == 255;
                const literal_value = if (immediate) try self.literal(wi, &count) else 0;
                const dst = (w0 >> 17) & 0xff;
                const src1 = (w0 >> 9) & 0xff;
                try self.append(w0);
                if (immediate) try self.append(literal_value);
                const base = Base{ .pc = pc, .word_count = count };
                break :blk switch (fam) {
                    .vop2 => switch (id) {
                        0x03 => .{ .v_add_f32 = .{ .base = base, .op = id, .dst = dst, .src0 = src0, .src1 = src1, .literal = immediate } },
                        0x04 => .{ .v_sub_f32 = .{ .base = base, .op = id, .dst = dst, .src0 = src0, .src1 = src1, .literal = immediate } },
                        0x05 => .{ .v_subrev_f32 = .{ .base = base, .op = id, .dst = dst, .src0 = src0, .src1 = src1, .literal = immediate } },
                        0x08 => .{ .v_mul_f32 = .{ .base = base, .op = id, .dst = dst, .src0 = src0, .src1 = src1, .literal = immediate } },
                        0x0f => .{ .v_min_f32 = .{ .base = base, .op = id, .dst = dst, .src0 = src0, .src1 = src1, .literal = immediate } },
                        0x10 => .{ .v_max_f32 = .{ .base = base, .op = id, .dst = dst, .src0 = src0, .src1 = src1, .literal = immediate } },
                        0x1f => .{ .v_mac_f32 = .{ .base = base, .op = id, .dst = dst, .src0 = src0, .src1 = src1, .literal = immediate } },
                        else => try self.unsupported(fam, w0, count, "unsupported VOP2 opcode", false),
                    },
                    .vopc => .{ .v_cmp = .{ .base = base, .op = id, .src0 = src0, .src1 = src1, .literal = immediate } },
                    .vop1 => switch ((w0 >> 9) & 0xff) {
                        0x01 => .{ .v_mov_b32 = .{ .base = base, .op = (w0 >> 9) & 0xff, .dst = dst, .src0 = src0, .literal = immediate } },
                        else => try self.unsupported(fam, w0, count, "unsupported VOP1 opcode", false),
                    },
                    else => unreachable,
                };
            },
            .vintrp => blk: {
                // Identical layout to RDNA2: OP[17:16], ATTR[15:10], VSRC[7:0].
                try self.append(w0);
                const op = (w0 >> 16) & 3;
                const base = Base{ .pc = pc, .word_count = count };
                const payload = Vintrp{
                    .base = base,
                    .op = op,
                    .attr = (w0 >> 10) & 0x3f,
                    .dst = (w0 >> 18) & 0xff,
                    .src = w0 & 0xff,
                };
                break :blk switch (op) {
                    0 => .{ .v_interp_p1_f32 = payload },
                    1 => .{ .v_interp_p2_f32 = payload },
                    else => try self.unsupported(fam, w0, count, "unsupported VINTRP opcode", false),
                };
            },
            .vop3 => blk: {
                // Use the 10-bit OP[25:16] form (GCN 1.2 / RDNA2), matching the
                // writer's 0x141 v_mad_f32 encoding.
                const op = (w0 >> 16) & 0x3ff;
                if (wi + 1 >= self.words.len) return Error.TruncatedInstruction;
                const w1 = self.words[wi + 1];
                count = 2;
                const src0 = w1 & 0x1ff;
                const immediate = src0 == 255;
                const literal_value = if (immediate) try self.literal(wi, &count) else 0;
                try self.append(w0);
                try self.append(w1);
                if (immediate) try self.append(literal_value);
                const base = Base{ .pc = pc, .word_count = count };
                break :blk if (op == 0x141)
                    Instruction{ .v_mad_f32 = .{
                        .base = base,
                        .op = op,
                        .dst = w0 & 0xff,
                        .src0 = src0,
                        .src1 = (w1 >> 9) & 0x1ff,
                        .src2 = (w1 >> 18) & 0x1ff,
                        .literal = immediate,
                    } }
                else
                    try self.unsupported(fam, w0, count, "unsupported VOP3 opcode", false);
            },
            .mubuf => blk: {
                if (wi + 1 >= self.words.len) return Error.TruncatedInstruction;
                const w1 = self.words[wi + 1];
                count = 2;
                // GCN 1.0/1.1 word1 matches GFX10's layout exactly.
                // shortcut: GFX9 byte-permuted MUBUF word1 is not handled;
                // upgrade when a GFX9 PS4 title is supported.
                try self.append(w0);
                try self.append(w1);
                const op = (w0 >> 18) & 0x7f;
                const base = Base{ .pc = pc, .word_count = count };
                break :blk if (op == 0x03)
                    Instruction{ .buffer_load_format_xyzw = .{
                        .base = base,
                        .op = op,
                        .dst = (w1 >> 8) & 0xff,
                        .vaddr = w1 & 0xff,
                        .srsrc = (w1 >> 16) & 0x1f,
                        .soffset = w1 >> 24,
                        .offset = w0 & 0xfff,
                        .idxen = (w0 >> 13) & 1 != 0,
                        .ofen = (w0 >> 12) & 1 != 0,
                    } }
                else
                    try self.unsupported(fam, w0, count, "unsupported MUBUF opcode", false);
            },
            .mimg => blk: {
                if (wi + 1 >= self.words.len) return Error.TruncatedInstruction;
                const w1 = self.words[wi + 1];
                count = 2;
                // GCN has no DIM field; GFX10 reads DIM from word0[5:3].
                // Force dim_2d (001) for the writer's sampled-image path.
                try self.append((w0 & ~@as(u32, 0x38)) | 0x08);
                try self.append(w1);
                const op = (w0 >> 18) & 0x7f;
                const base = Base{ .pc = pc, .word_count = count };
                break :blk if (op == 0x20)
                    Instruction{ .image_sample = .{
                        .base = base,
                        .op = op,
                        .dmask = @intCast((w0 >> 8) & 0xf),
                        .dst = (w1 >> 8) & 0xff,
                        .addr = w1 & 0xff,
                        .tsgpr = ((w1 >> 16) & 0x1f) * 4,
                        .ssgpr = ((w1 >> 21) & 0x1f) * 4,
                    } }
                else
                    try self.unsupported(fam, w0, count, "unsupported MIMG opcode", false);
            },
            .exp => blk: {
                if (wi + 1 >= self.words.len) return Error.TruncatedInstruction;
                const w1 = self.words[wi + 1];
                count = 2;
                try self.append(w0);
                try self.append(w1);
                break :blk Instruction{ .exp = .{
                    .base = .{ .pc = pc, .word_count = count },
                    .target = @intCast((w0 >> 4) & 0x3f),
                    .enable = @intCast(w0 & 0xf),
                    .done = (w0 >> 11) & 1 != 0,
                    .src = .{ @truncate(w1), @truncate(w1 >> 8), @truncate(w1 >> 16), @truncate(w1 >> 24) },
                } };
            },
            else => try self.unsupported(fam, w0, count, "unsupported GCN encoding family", true),
        };
        self.index = wi + count;
        return result;
    }
};

pub fn decode(words: []const u32) Iterator {
    return .{ .words = words, .allocator = std.heap.page_allocator };
}

pub fn decodeWithAllocator(allocator: std.mem.Allocator, words: []const u32) Iterator {
    return .{ .words = words, .allocator = allocator };
}

pub fn decodeAll(allocator: std.mem.Allocator, words: []const u32) Error![]Instruction {
    var list: std.ArrayList(Instruction) = .empty;
    errdefer list.deinit(allocator);
    var it = decodeWithAllocator(allocator, words);
    while (try it.next()) |inst| try list.append(allocator, inst);
    return try list.toOwnedSlice(allocator);
}

/// A normalized GFX10 program plus the owned word buffer `program.code` points
/// into. The caller must deinit it.
pub const Rdna2Program = struct {
    program: rdna2.Program,
    normalized: []u32,

    pub fn deinit(self: *Rdna2Program, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        allocator.free(self.normalized);
    }
};

pub fn decodeToRdna2(allocator: std.mem.Allocator, words: []const u32) Error!Rdna2Program {
    var normalized: std.ArrayList(u32) = .empty;
    errdefer normalized.deinit(allocator);
    var it = decodeWithAllocator(allocator, words);
    it.normalized = &normalized;
    while (try it.next()) |_| {}
    const owned = try normalized.toOwnedSlice(allocator);
    const program = rdna2.decodeProgram(allocator, owned) catch return Error.UnsupportedInstruction;
    return .{ .program = program, .normalized = owned };
}

// ---- encoding helpers (used by tests and by future shader captures) ----

pub fn vop2(op: u32, dst: u32, src1: u32, src0: u32) u32 {
    return (op << 25) | (dst << 17) | (src1 << 9) | src0;
}
pub fn vop1(op: u32, dst: u32, src0: u32) u32 {
    return 0x7e00_0000 | (dst << 17) | (op << 9) | src0;
}
pub fn vintrp(p2: bool, dst: u32, attr: u32, src: u32) u32 {
    return 0xc800_0000 | (dst << 18) | (@as(u32, @intFromBool(p2)) << 16) | (attr << 10) | src;
}
pub fn smrd(op: u32, dst: u32, sbase: u32, offset: u32) u32 {
    return 0xc000_0000 | (op << 22) | (dst << 15) | (sbase << 9) | (1 << 8) | (offset & 0xff);
}
pub fn mimg(op: u32, dmask: u4, dst: u32, addr: u32, tsgpr: u32, ssgpr: u32) [2]u32 {
    return .{
        0xf000_0000 | (op << 18) | (@as(u32, dmask) << 8),
        (ssgpr << 21) | (tsgpr << 16) | (dst << 8) | addr,
    };
}
pub fn exp(target: u6, enable: u4, done: bool, src: [4]u8) [2]u32 {
    return .{
        0xf800_0000 | (@as(u32, target) << 4) | enable | (@as(u32, @intFromBool(done)) << 11),
        @as(u32, src[0]) | (@as(u32, src[1]) << 8) | (@as(u32, src[2]) << 16) | (@as(u32, src[3]) << 24),
    };
}

// ---- tests ----

const sprite_ps = [_]u32{
    vintrp(false, 0, 0, 0), // v_interp_p1_f32 v0, v0, attr 0
    vintrp(true, 1, 0, 0), // v_interp_p2_f32 v1, v0, attr 0
    vintrp(false, 2, 1, 0), // v_interp_p1_f32 v2, v0, attr 1
    vintrp(true, 3, 1, 0), // v_interp_p2_f32 v3, v0, attr 1
    0xbf8c_0000, // s_waitcnt (lowered to s_nop)
    mimg(0x20, 0xf, 4, 0, 0, 2)[0],
    mimg(0x20, 0xf, 4, 0, 0, 2)[1],
    vop2(0x08, 4, 4, 0x102), // v_mul_f32 v4, v4, v2
    exp(0, 0xf, true, .{ 4, 4, 4, 4 })[0],
    exp(0, 0xf, true, .{ 4, 4, 4, 4 })[1],
    0xbf81_0000, // s_endpgm
};

test "GCN top-level family dispatch uses real encoding numbers" {
    try std.testing.expectEqual(Family.vop2, family(vop2(0x03, 2, 1, 0x101)));
    try std.testing.expectEqual(Family.vop1, family(vop1(0x01, 2, 0x101)));
    try std.testing.expectEqual(Family.vopc, family(0x7c00_0000));
    try std.testing.expectEqual(Family.sop1, family(0xbe80_0301));
    try std.testing.expectEqual(Family.sopp, family(0xbf81_0000));
    try std.testing.expectEqual(Family.smrd, family(smrd(0x02, 8, 1, 0)));
    try std.testing.expectEqual(Family.vintrp, family(vintrp(false, 0, 0, 0)));
    try std.testing.expectEqual(Family.mimg, family(0xf000_0000));
    try std.testing.expectEqual(Family.exp, family(0xf800_0000));
}

test "sprite pixel shader decodes to the expected instruction sequence" {
    const insts = try decodeAll(std.testing.allocator, &sprite_ps);
    defer std.testing.allocator.free(insts);
    const want = [_]Tag{
        .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_p1_f32, .v_interp_p2_f32,
        .s_waitcnt,       .image_sample,    .v_mul_f32,       .exp,
        .s_endpgm,
    };
    try std.testing.expectEqual(want.len, insts.len);
    for (want, insts) |expected, inst| try std.testing.expectEqual(expected, inst.tag());

    const image = insts[5].image_sample;
    try std.testing.expectEqual(@as(u4, 0xf), image.dmask);
    try std.testing.expectEqual(@as(u32, 0), image.tsgpr);
    try std.testing.expectEqual(@as(u32, 8), image.ssgpr);
    const output = insts[7].exp;
    try std.testing.expectEqual(@as(u6, 0), output.target);
    try std.testing.expectEqual(@as(u4, 0xf), output.enable);
    try std.testing.expect(output.done);
}

test "SOPP branches use word-scaled byte targets" {
    const code = [_]u32{ 0xbf82_0002, 0xbf81_0000, 0xbf81_0000 }; // s_branch +2
    const insts = try decodeAll(std.testing.allocator, &code);
    defer std.testing.allocator.free(insts);
    try std.testing.expectEqual(Tag.s_branch, insts[0].tag());
    try std.testing.expectEqual(@as(u32, 12), insts[0].s_branch.target);
}

test "SMRD re-encodes to a two-word RDNA2 SMEM load" {
    const words = [_]u32{ smrd(0x02, 8, 1, 0x10), 0xbf81_0000 };
    var decoded = try decodeToRdna2(std.testing.allocator, &words);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.program.instructions.items.len);
    try std.testing.expectEqual(rdna2.Opcode.s_load_dwordx4, decoded.program.instructions.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 8), decoded.program.instructions.items[1].pc);
}
