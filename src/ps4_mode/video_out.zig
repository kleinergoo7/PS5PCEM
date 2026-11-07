// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 VideoOut compatibility: resolution-status layout + flip status.
//!
//! PS4 `sceVideoOut` returns a narrower resolution-status struct than the PS5
//! one and numbers flip timing differently. These helpers convert between the
//! PS4 guest layout and the native representation VideoOut HLE already uses,
//! so the presenter needs no PS4-specific branch beyond calling `normalize`.

const std = @import("std");

/// PS4 resolution-status layout (packed, little-endian on the wire).
pub const Ps4ResolutionStatus = extern struct {
    width: u32,
    height: u32,
    refresh_hz: u32, // scaled by 100 (5994 = 59.94 Hz)
    _reserved: u32 = 0,
};

/// Native (PS5PCEM) resolution view.
pub const Resolution = struct {
    width: u32,
    height: u32,
    refresh_num: u32, // e.g. 5994
    refresh_den: u32, // e.g. 100
};

pub fn normalize(status: Ps4ResolutionStatus) Resolution {
    return .{
        .width = status.width,
        .height = status.height,
        .refresh_num = status.refresh_hz,
        .refresh_den = 100,
    };
}

pub fn denormalize(res: Resolution) Ps4ResolutionStatus {
    const hz: u32 = if (res.refresh_den == 0) 6000 else res.refresh_num * 100 / res.refresh_den;
    return .{ .width = res.width, .height = res.height, .refresh_hz = hz };
}

/// Flip status compat: PS4 counts flips since buffer registration; PS5 counts
/// since submit. The delta is the registration offset the caller tracks.
pub fn flipCountForGuest(native_count: u64, registration_offset: u64) u64 {
    return native_count -| registration_offset;
}
