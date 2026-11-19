// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Runner hook: the 3-line call site for game-run / launchers.
//!
//! ```zig
//! const ps4_hook = @import("ps4_mode/game_hook.zig");
//! const mode = ps4_hook.decideForBlobs(param_sfo_bytes, eboot_bytes);
//! const cfg = ps4_hook.configFromEnv(); // PS5_PS4_MODE / PS5_GNM_DIAG
//! if (cfg.enabledFor(mode)) { /* PS4 path: default-state preamble + bridge */ }
//! ```
//!
//! Kept dependency-light on purpose: blobs in, verdict out. File/network IO
//! stays in the caller, so headless tools and the GUI share this file.

const std = @import("std");
const detector = @import("detector.zig");
const runtime = @import("runtime.zig");

pub const decideForBlobs = detector.decideFromBlobs;
pub const configFrom = runtime.configFrom;

/// Once-per-process config. Zig 0.16 has no global `getenv`, so the runner seeds
/// these values from its environment block before calling `configFromEnv()`.
var seeded_config: ?runtime.Config = null;

/// Seed the cached env values. `null` policy means PS5_PS4_MODE was unset.
/// PS4-mode libc I/O shim gate. Set from the launch config before guest module
/// loading, so the linker can prefer the HLE fopen/fread/... exports over the
/// title's bundled libc PRX. Native PS5 titles leave this false.
pub var libc_io_active: bool = false;

pub fn seedEnvConfig(policy_value: ?[]const u8, diag: bool) void {
    seeded_config = configFrom(policy_value, diag);
    libc_io_active = seeded_config.?.policy == .on;
}

/// Return the env-derived config seeded by the runner (auto policy if unseeded).
pub fn configFromEnv() runtime.Config {
    return seeded_config orelse configFrom(null, false);
}

/// Environment override names (single source of truth for docs + launchers).
pub const env_mode = "PS5_PS4_MODE";
pub const env_diag = "PS5_GNM_DIAG";

/// Log line for startup diagnostics: mode label + whether compat is active.
pub fn startupLine(mode: detector.Mode, cfg: runtime.Config, buf: []u8) []const u8 {
    const active: []const u8 = if (cfg.enabledFor(mode)) "active" else "inactive";
    const label = mode.label();
    var n: usize = 0;
    const prefix = "[ps4_mode] mode=";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    @memcpy(buf[n..][0..label.len], label);
    n += label.len;
    const mid = " compat=";
    @memcpy(buf[n..][0..mid.len], mid);
    n += mid.len;
    @memcpy(buf[n..][0..active.len], active);
    n += active.len;
    return buf[0..n];
}

test "configFromEnv: PS5_PS4_MODE=on enables compat, absent follows auto policy" {
    // PS5_PS4_MODE=on
    seedEnvConfig("on", false);
    const forced = configFromEnv();
    try std.testing.expect(forced.enabledFor(.ps4_gnm));
    try std.testing.expect(forced.enabledFor(.ps5_native));

    // PS5_PS4_MODE unset -> auto policy
    seedEnvConfig(null, false);
    const automatic = configFromEnv();
    try std.testing.expectEqual(runtime.Policy.auto, automatic.policy);
    try std.testing.expect(automatic.enabledFor(.ps4_gnm));
    try std.testing.expect(!automatic.enabledFor(.ps5_native));
}
