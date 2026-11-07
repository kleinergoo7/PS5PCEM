// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Tessellation pair tracking and offchip/factor-ring configuration.
//!
//! PS4 tessellation ships hull (local+HS) and domain shaders as separate
//! blobs that must be joined before the shared pipeline cache sees them.
//! This module tracks HS/DS pairing per draw plus the offchip buffer and
//! tessellation-factor ring both stages need. Pure state machine; the actual
//! HS/DS lowering stays in gpu/tessellation.zig + rdna2/.

const std = @import("std");
const gcn_header = @import("gcn_header.zig");

/// Offchip buffer + TF ring configuration (guest addresses + sizes).
pub const OffchipConfig = struct {
    offchip_addr: u64 = 0,
    offchip_size: u32 = 0,
    tf_ring_addr: u64 = 0,
    tf_ring_size: u32 = 0,
    max_offchip_waves: u16 = 0,

    pub fn isConfigured(self: OffchipConfig) bool {
        return self.offchip_addr != 0 and self.tf_ring_addr != 0;
    }
};

/// One hull/domain pair joined for a single patch draw.
pub const TessPair = struct {
    hull_id: u64, // hash/identity of the HS blob (caller-assigned)
    domain_id: u64, // hash/identity of the DS blob
    hull_is_pair: bool, // HS blob carries its local entry
    patch_type: u8, // 0 = isolines, 1 = triangles, 2 = quads

    pub fn isComplete(self: TessPair) bool {
        return self.hull_id != 0 and self.domain_id != 0;
    }
};

/// Validate that a blob pair can be joined: stages must be hull+domain and
/// both must agree on tessellation usage.
pub fn canJoin(hull: gcn_header.Header, domain: gcn_header.Header) bool {
    if (hull.stage != .hull or domain.stage != .domain) return false;
    return hull.uses_tessellation and domain.uses_tessellation;
}

/// Pick the domain-stage input control from the patch type.
/// Returns the VGT primitive type the backend programs.
pub fn vgtPrimitiveForPatch(patch_type: u8) u8 {
    return switch (patch_type) {
        0 => 0x0c, // isolines
        1 => 0x0e, // triangles
        2 => 0x10, // quads
        else => 0x0e,
    };
}
