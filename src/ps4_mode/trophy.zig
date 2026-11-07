// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 trophy (TRP) metadata model.
//!
//! PS4 trophy packages use the TRP container with AES-encrypted ESFM metadata
//! keyed by a user-supplied 128-bit trophy key + the package NP communication
//! ID. Key material is never bundled; this module models package metadata,
//! trophy links, and platinum eligibility so the existing trophy system can
//! consume PS4 layouts (first set: trophy00.trp, service label 0).

const std = @import("std");

pub const Grade = enum(u8) {
    bronze = 0,
    silver = 1,
    gold = 2,
    platinum = 3,
    _,

    pub fn label(self: Grade) []const u8 {
        return switch (self) {
            .bronze => "bronze",
            .silver => "silver",
            .gold => "gold",
            .platinum => "platinum",
            else => "unknown",
        };
    }
};

/// One trophy entry: links bind DLC trophies to their own set so unrelated
/// DLC never blocks the base game's platinum.
pub const Trophy = struct {
    id: u32,
    grade: Grade,
    set_index: u8, // 0 = base (trophy00), 1+ = DLC sets
    linked_platinum: bool, // counts toward a platinum
    unlocked: bool = false,
};

/// Platinum eligibility: every linked non-platinum trophy in the base set is
/// unlocked, and the platinum itself is not yet unlocked.
pub fn platinumEligible(trophies: []const Trophy, set_index: u8) bool {
    var saw_plat = false;
    for (trophies) |t| {
        if (t.set_index != set_index) continue;
        if (t.grade == .platinum) {
            if (t.unlocked) return false;
            saw_plat = true;
            continue;
        }
        if (t.linked_platinum and !t.unlocked) return false;
    }
    return saw_plat;
}

/// Count unlocked trophies in a set (for progress dialogs).
pub fn unlockedCount(trophies: []const Trophy, set_index: u8) u32 {
    var n: u32 = 0;
    for (trophies) |t| {
        if (t.set_index == set_index and t.unlocked) n += 1;
    }
    return n;
}
