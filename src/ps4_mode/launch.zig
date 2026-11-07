// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Launch integration: session bootstrap, badges, and LoadExec.
//!
//! Pure helpers the CLI/GUI call: bootstrap a `runtime.Session` from raw
//! param.sfo + eboot bytes, report the library badge string, and resolve the
//! launch profile (which backend + env the title needs). No OS calls here so
//! both launchers share this file.

const std = @import("std");
const detector = @import("detector.zig");
const runtime = @import("runtime.zig");
const sfo = @import("sfo.zig");

/// Badge shown in the game library for compatibility titles.
pub fn badgeFor(mode: detector.Mode) []const u8 {
    return switch (mode) {
        .ps4_gnm => "PS4 · GNM",
        .ps5_native => "",
        .unknown => "unverified",
    }
}

/// Launch profile: what the runner needs beyond the executable path.
pub const LaunchProfile = struct {
    use_ps4_mode: bool,
    diag: bool,
    backend: []const u8, // "vulkan" (only supported renderer for GNM titles)
};

pub fn resolveProfile(session: runtime.Session) LaunchProfile {
    return .{
        .use_ps4_mode = session.active(),
        .diag = session.config.diag,
        .backend = "vulkan",
    };
}

/// Bootstrap a session from raw blobs. Never fails: unknown content yields an
/// inactive session with policy intact, so the caller always launches native.
pub fn bootstrap(
    session: *runtime.Session,
    param_sfo: ?[]const u8,
    eboot: ?[]const u8,
    cfg: runtime.Config,
) void {
    var title_id: ?[]const u8 = null;
    if (param_sfo) |psf| {
        title_id = sfo.getString(psf, "TITLE_ID") catch null;
    }
    const e_type: ?u16 = if (eboot) |exe| detector.elfTypeOf(exe) else null;
    session.mode = detector.decide(title_id, e_type);
    session.config = cfg;
    if (title_id) |id| {
        const n = @min(id.len, session.title_id.len);
        @memcpy(session.title_id[0..n], id[0..n]);
        session.title_id_len = @intCast(n);
    } else {
        session.title_id_len = 0;
    }
}
