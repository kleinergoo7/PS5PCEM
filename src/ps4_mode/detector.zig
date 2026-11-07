// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 title detection.
//!
//! Mirrors SharpEmu's "detect compatibility applications" step: before any
//! translation runs, decide whether a content directory is a PS4 (GNM) title,
//! a native PS5 title, or unknown. The decision uses three independent
//! signals so one corrupt file cannot flip the mode:
//!
//! 1. TITLE_ID prefix from param.sfo (CUSA = PS4-era, PPSA/ELAS = PS5-era).
//! 2. ELF object type of eboot.bin (PS4: 0xFE00 ET_SCE_DYNEXEC,
//!    PS5: 0xFE10; see loader/elf.zig for the PS5 values).
//! 3. Explicit override via PS5_PS4_MODE env (auto/off/on), handled in
//!    runtime.zig; this file only classifies content.

const std = @import("std");
const sfo = @import("sfo.zig");

pub const Mode = enum {
    unknown,
    ps5_native,
    ps4_gnm,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .ps5_native => "ps5-native",
            .ps4_gnm => "ps4-gnm",
        };
    }
};

/// PS4 dynamic-executable object type (older SDK tooling).
pub const elf_sce_dynexec_ps4: u16 = 0xfe00;
/// PS5 dynamic-executable object type (matches loader/elf.zig).
pub const elf_sce_dynexec_ps5: u16 = 0xfe10;
/// PS4 shared-library object type.
pub const elf_sce_dynamic_ps4: u16 = 0xfe01;
/// PS5 shared-library object type (matches loader/elf.zig).
pub const elf_sce_dynamic_ps5: u16 = 0xfe18;

/// Classify a TITLE_ID string. Prefixes follow Sony's numbering:
/// CUSA/PCAS = PS4 era, PPSA/ELAS/ECAS = PS5 era.
pub fn classifyTitleId(title_id: []const u8) Mode {
    if (title_id.len < 4) return .unknown;
    const prefix = title_id[0..4];
    if (std.mem.eql(u8, prefix, "CUSA") or std.mem.eql(u8, prefix, "PCAS")) return .ps4_gnm;
    if (std.mem.eql(u8, prefix, "PPSA") or std.mem.eql(u8, prefix, "ELAS") or std.mem.eql(u8, prefix, "ECAS")) return .ps5_native;
    return .unknown;
}

/// Classify an ELF `e_type` field read from eboot.bin's header (offset 16).
pub fn classifyElfType(e_type: u16) Mode {
    return switch (e_type) {
        elf_sce_dynexec_ps4, elf_sce_dynamic_ps4 => .ps4_gnm,
        elf_sce_dynexec_ps5, elf_sce_dynamic_ps5 => .ps5_native,
        else => .unknown,
    };
}

/// Read `e_type` from raw ELF bytes. Returns null when too short / not ELF.
pub fn elfTypeOf(bytes: []const u8) ?u16 {
    if (bytes.len < 18) return null;
    if (bytes[0] != 0x7f or bytes[1] != 'E' or bytes[2] != 'L' or bytes[3] != 'F') return null;
    return std.mem.readInt(u16, bytes[16..18], .little);
}

/// Combined verdict: TITLE_ID wins when present; ELF type breaks ties and
/// confirms; disagreement resolves to PS4 only when the TITLE_ID itself is a
/// PS4 prefix (a re-wrapped executable keeps its generation's content ID).
pub fn decide(title_id: ?[]const u8, e_type: ?u16) Mode {
    const from_id: Mode = if (title_id) |id| classifyTitleId(id) else .unknown;
    const from_elf: Mode = if (e_type) |t| classifyElfType(t) else .unknown;
    if (from_id == .ps4_gnm) return .ps4_gnm;
    if (from_id != .unknown) return from_id;
    return from_elf;
}

/// Convenience wrapper over a param.sfo blob plus optional eboot bytes.
pub fn decideFromBlobs(param_sfo: ?[]const u8, eboot: ?[]const u8) Mode {
    var title_id: ?[]const u8 = null;
    if (param_sfo) |psf| {
        title_id = sfo.getString(psf, "TITLE_ID") catch null;
    }
    const e_type: ?u16 = if (eboot) |exe| elfTypeOf(exe) else null;
    return decide(title_id, e_type);
}

test "title id prefixes classify generations" {
    try std.testing.expectEqual(Mode.ps4_gnm, classifyTitleId("CUSA00001"));
    try std.testing.expectEqual(Mode.ps4_gnm, classifyTitleId("PCAS00001"));
    try std.testing.expectEqual(Mode.ps5_native, classifyTitleId("PPSA21564"));
    try std.testing.expectEqual(Mode.ps5_native, classifyTitleId("ELAS12345"));
    try std.testing.expectEqual(Mode.unknown, classifyTitleId("??"));
    try std.testing.expectEqual(Mode.unknown, classifyTitleId(""));
}

test "elf object types classify generations" {
    try std.testing.expectEqual(Mode.ps4_gnm, classifyElfType(0xfe00));
    try std.testing.expectEqual(Mode.ps5_native, classifyElfType(0xfe10));
    try std.testing.expectEqual(Mode.unknown, classifyElfType(2));
}

test "ps4 title id wins over mismatched elf type" {
    try std.testing.expectEqual(Mode.ps4_gnm, decide("CUSA00001", 0xfe10));
    try std.testing.expectEqual(Mode.ps5_native, decide("PPSA21564", null));
    try std.testing.expectEqual(Mode.unknown, decide(null, null));
}
