// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 service-layout helpers (NP, savedata, trophy glue).
//!
//! Pure layout conversion for the second wave of compat services; the guest
//! entry points themselves stay in the PS5 implementations until per-service
//! bring-up. Referenced from hle/root.zig so it compiles with the module.

const std = @import("std");

/// PS4 NP trophy-context layout: service label selects the trophy set
/// (label 0 = trophy00.trp base set).
pub const TrophyContext = struct {
    service_label: u32,
    comm_id: [10]u8,

    pub fn isBaseSet(self: TrophyContext) bool {
        return self.service_label == 0;
    }
};

/// PS4 savedata mount point: title/user-scoped directory name builder.
/// Writes `CUSAxxxxx-<user_id>` style names into `out`, returns bytes written.
pub fn mountName(title_id: []const u8, user_id: u32, out: []u8) usize {
    var n: usize = 0;
    const tid_len = @min(title_id.len, 9);
    if (out.len < tid_len + 1 + 8) return 0;
    @memcpy(out[n..][0..tid_len], title_id[0..tid_len]);
    n += tid_len;
    out[n] = '-';
    n += 1;
    var tmp: [8]u8 = undefined;
    var v = user_id;
    var digits: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        digits = 1;
    } else {
        var rev: [8]u8 = undefined;
        while (v > 0 and digits < rev.len) : (digits += 1) {
            rev[digits] = @intCast('0' + (v % 10));
            v /= 10;
        }
        var i: usize = 0;
        while (i < digits) : (i += 1) {
            tmp[i] = rev[digits - 1 - i];
        }
    }
    @memcpy(out[n..][0..digits], tmp[0..digits]);
    n += digits;
    return n;
}

/// Offline TUS (title user storage) completion: PS4 offline requests complete
/// immediately with a benign status instead of hitting the network.
pub const offline_tus_status_ok: i32 = 0;
