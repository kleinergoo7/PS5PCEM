// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4-mode runtime session: env switches, diagnostics gating, LoadExec.
//!
//! Environment contract (documented in docs/ps4-mode.md):
//!   PS5_PS4_MODE = auto|on|off   (default auto)
//!   PS5_GNM_DIAG = 0|1           (default 0; extra compat logging)
//!
//! LoadExec (game switching without relaunch) is modelled as an explicit
//! session transition so CLI/GUI restarts stay in one place.

const std = @import("std");
const detector = @import("detector.zig");

pub const Policy = enum {
    auto,
    on,
    off,

    pub fn fromString(s: []const u8) ?Policy {
        if (std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(s, "on") or std.ascii.eqlIgnoreCase(s, "1")) return .on;
        if (std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "0")) return .off;
        return null;
    }
};

pub const Config = struct {
    policy: Policy = .auto,
    diag: bool = false,

    pub fn enabledFor(self: Config, mode: detector.Mode) bool {
        return switch (self.policy) {
            .on => true,
            .off => false,
            .auto => mode == .ps4_gnm,
        };
    }
};

/// Parse env-style overrides without touching the real environment (testable).
pub fn configFrom(policy_str: ?[]const u8, diag: bool) Config {
    var cfg = Config{ .diag = diag };
    if (policy_str) |s| cfg.policy = Policy.fromString(s) orelse .auto;
    return cfg;
}

/// Read the real process environment. Never fails: unknown values fall back
/// to defaults so a typo cannot brick launching.
pub fn configFromEnv() Config {
    var cfg = Config{};
    if (std.posix.getenv("PS5_PS4_MODE")) |v| {
        cfg.policy = Policy.fromString(v) orelse .auto;
    }
    if (std.posix.getenv("PS5_GNM_DIAG")) |v| {
        cfg.diag = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "on");
    }
    return cfg;
}

/// Minimal session: what the launchers need to cache per title.
pub const Session = struct {
    title_id: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    title_id_len: u8 = 0,
    mode: detector.Mode = .unknown,
    config: Config = .{},

    pub fn titleId(self: *const Session) []const u8 {
        return self.title_id[0..self.title_id_len];
    }

    pub fn active(self: *const Session) bool {
        return self.config.enabledFor(self.mode);
    }

    /// LoadExec transition: replace the title id + mode, keep user policy.
    pub fn retarget(self: *Session, new_title_id: []const u8, new_mode: detector.Mode) void {
        const n = @min(new_title_id.len, self.title_id.len);
        @memcpy(self.title_id[0..n], new_title_id[0..n]);
        self.title_id_len = @intCast(n);
        self.mode = new_mode;
    }
};

test "auto enables only ps4 titles" {
    const cfg = configFrom("auto", false);
    try std.testing.expect(cfg.enabledFor(.ps4_gnm));
    try std.testing.expect(!cfg.enabledFor(.ps5_native));
    try std.testing.expect(!cfg.enabledFor(.unknown));
}

test "explicit on/off override detection" {
    try std.testing.expect(configFrom("on", false).enabledFor(.ps5_native));
    try std.testing.expect(!configFrom("off", false).enabledFor(.ps4_gnm));
    try std.testing.expectEqual(Policy.auto, configFrom("bogus", false).policy);
}

test "session retarget keeps policy" {
    var s = Session{ .mode = .ps4_gnm, .config = configFrom("auto", true) };
    try std.testing.expect(s.active());
    s.retarget("PPSA21564", .ps5_native);
    try std.testing.expectEqualStrings("PPSA21564", s.titleId());
    try std.testing.expect(!s.active());
}
