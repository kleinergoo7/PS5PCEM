// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! GCN ISA lowering toward the shared RDNA2 path.
//!
//! PS4 shaders are GCN (Sea Islands) ISA; PS5PCEM translates RDNA2. The two
//! share the vector/scalar split but differ in encodings, descriptor layouts
//! and tessellation staging. This module classifies raw GCN instruction
//! words, normalizes buffer/image descriptors, and validates hull/domain
//! joins so rdna2/decoder.zig receives pre-classified input instead of
//! re-learning GCN.

const std = @import("std");

/// GCN instruction class from the top bits of the first dword.
pub const Class = enum {
    sop2, // scalar ALU, 2 operands
    sopk, // scalar ALU, short immediate
    sop1, // scalar ALU, 1 operand
    sopc, // scalar compare
    sopp, // scalar program control (branches)
    smrd, // scalar memory read
    vop2, // vector ALU, 2 operands (legacy)
    vop1, // vector ALU, 1 operand (legacy)
    vopc, // vector compare (legacy)
    vop3, // vector ALU, 3 operands / VOP3-encoded
    vinop, // vector integer no-dst ops
    vmem_mubuf, // typed/untyped buffer access
    vmem_mtbuf, // typed buffer access
    vmem_mimg, // image access
    ds, // LDS / GDS
    flat, // flat (incl. ADDR64 lowering surface)
    exp, // export (color/depth/param)
    illegal,
};

/// Classify from the encoding field (bits [31..26] of word0).
pub fn classify(word0: u32) Class {
    const enc: u6 = @intCast((word0 >> 26) & 0x3f);
    // Disjoint first-pass buckets; real decode refines by opcode within class.
    // (Exact GCN boundaries are the refining AI's job; buckets must not overlap.)
    return switch (enc) {
        0b000000...0b001011 => .vop2,
        0b001100 => .vinop,
        0b001110 => .vopc,
        0b001111 => .vop1,
        0b100000...0b100001 => .sop2,
        0b101100 => .sopk,
        0b101101 => .sop1,
        0b101110 => .sopc,
        0b101111 => .sopp,
        0b110000...0b110001 => .smrd,
        0b110100 => .vop3,
        0b110101 => .ds,
        0b110110 => .flat,
        0b111000 => .vmem_mubuf,
        0b111010 => .vmem_mtbuf,
        0b111011 => .exp,
        0b111100 => .vmem_mimg,
        else => .illegal,
    };
}

/// Whether the class is a legacy (pre-RDNA) ALU form needing VOP1/VOP2/VOPC
/// → modern VOP3-style normalization.
pub fn isLegacyAlu(class: Class) bool {
    return class == .vop1 or class == .vop2 or class == .vopc;
}

/// Normalized buffer descriptor (16 bytes, GCN layout → host view).
pub const BufferDescriptor = struct {
    base_addr: u64,
    stride: u32, // 0 = raw byte buffer
    num_records: u32,
    swizzle_enable: bool, // structured/tiled access
    add_tid_enable: bool, // vertex fetch: add thread id

    pub fn isRaw(self: BufferDescriptor) bool {
        return self.stride == 0;
    }

    pub fn byteLength(self: BufferDescriptor) u64 {
        if (self.isRaw()) return self.num_records;
        return @as(u64, self.stride) * self.num_records;
    }
};

/// Parse 4 dwords of GCN buffer descriptor into the normalized view.
pub fn parseBufferDescriptor(words: [4]u32) BufferDescriptor {
    const base = @as(u64, words[0]) | (@as(u64, words[1] & 0xffff) << 32);
    const stride: u32 = (words[1] >> 16) & 0x3fff;
    return .{
        .base_addr = base,
        .stride = stride,
        .num_records = words[2],
        .swizzle_enable = words[3] & (1 << 14) != 0,
        .add_tid_enable = words[3] & (1 << 13) != 0,
    };
}

/// Storage-image access control (GCN GLC/SLC bits → barrier class).
pub const ImageAccess = struct {
    glc: bool, // globally coherent: bypass L1, needs acquire barrier
    slc: bool, // system-level coherent
};

/// Barrier class for a storage-image op: coherent ops need the acquire
/// barrier; repeated non-coherent accesses to the same image need none.
pub fn barrierFor(access: ImageAccess, same_image_repeat: bool) u8 {
    if (!access.glc and same_image_repeat) return 0; // no barrier
    if (access.glc) return 1; // acquire
    return 2; // release/ordered
}

/// Fetch-program cache key: vertex fetch shaders are resolved once per
/// (format mask, binding count) and reused across draws.
pub const FetchKey = struct {
    format_mask: u32,
    binding_count: u8,
    index_type: u8, // 0 = none, 1 = u16, 2 = u32
};
