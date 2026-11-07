// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 firmware-library compatibility table.
//!
//! SharpEmu registers "compatibility library exports" per PS4 module; the
//! PS5PCEM equivalent is this static table: for every PS4-era library the
//! loader may request, state whether the native PS5 implementation can be
//! reused as-is, needs argument/layout adaptation, or is currently a stub.
//! Pure data + lookup, so HLE wiring can consume it without importing HLE.

const std = @import("std");

pub const Disposition = enum {
    passthrough, // identical ABI: reuse the PS5 implementation
    adapt, // same concept, PS4 layout: translate at the boundary
    stub, // accepted, returns a benign default; logged
    unsupported, // rejected loudly

    pub fn label(self: Disposition) []const u8 {
        return switch (self) {
            .passthrough => "passthrough",
            .adapt => "adapt",
            .stub => "stub",
            .unsupported => "unsupported",
        };
    }
};

pub const Entry = struct {
    name: []const u8,
    disposition: Disposition,
    note: []const u8,
};

pub const table = [_]Entry{
    .{ .name = "libSceGnmDriver", .disposition = .adapt, .note = "GNM packets/shaders translate to AGC path" },
    .{ .name = "libSceVideoOut", .disposition = .adapt, .note = "PS4 resolution-status layout differs" },
    .{ .name = "libSceAudioOut", .disposition = .passthrough, .note = "Gen4 shared-output queries enabled" },
    .{ .name = "libSceAjm", .disposition = .adapt, .note = "codec/sideband constants shared" },
    .{ .name = "libSceAvPlayer", .disposition = .adapt, .note = "preserve guest stream selection" },
    .{ .name = "libSceNpManager", .disposition = .adapt, .note = "content-restriction queries" },
    .{ .name = "libSceNpTrophy", .disposition = .adapt, .note = "TRP container, PS4 layouts" },
    .{ .name = "libSceNpTus", .disposition = .stub, .note = "offline completion only" },
    .{ .name = "libSceSaveData", .disposition = .adapt, .note = "mounting adapted" },
    .{ .name = "libSceSaveDataDialog", .disposition = .stub, .note = "progress dialog held open" },
    .{ .name = "libScePad", .disposition = .passthrough, .note = "touchpad halves mapped" },
    .{ .name = "libSceUserService", .disposition = .adapt, .note = "legacy aliases registered" },
    .{ .name = "libSceSystemService", .disposition = .adapt, .note = "legacy hw/context init packets" },
    .{ .name = "libkernel", .disposition = .adapt, .note = "POSIX signals/mmap shared; addr reservations" },
    .{ .name = "libSceVideodec2", .disposition = .adapt, .note = "plane/picture metadata normalized" },
    .{ .name = "libSceAtrac9", .disposition = .adapt, .note = "RIFF input, gapless state" },
};

/// Look up a library by name. Returns null when the module is PS5-only and
/// needs no compat entry.
pub fn lookup(name: []const u8) ?Entry {
    for (table) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Count entries by disposition (for diagnostics lines).
pub fn countBy(d: Disposition) usize {
    var n: usize = 0;
    for (table) |e| {
        if (e.disposition == d) n += 1;
    }
    return n;
}

test "gnm driver routes through adapt" {
    const e = lookup("libSceGnmDriver") orelse return error.Missing;
    try std.testing.expectEqual(Disposition.adapt, e.disposition);
}

test "unknown ps5-only lib has no entry" {
    try std.testing.expect(lookup("libSceAgc") == null);
}

test "table covers all dispositions used" {
    try std.testing.expect(countBy(.adapt) > 0);
    try std.testing.expect(countBy(.passthrough) > 0);
    try std.testing.expect(countBy(.stub) > 0);
}
