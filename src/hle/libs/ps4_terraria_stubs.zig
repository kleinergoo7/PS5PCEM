// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 Terraria first-frame import closure.
//!
//! These are the 37 NIDs game-run enumerates as unresolved for Terraria (the
//! authoritative link queue; the larger module-info MISS list is only a
//! fallback). Each is registered under its exact PS4 NID via `id_override`, so
//! no PS5 export is shadowed. Every stub records its NID through
//! `ps4_mode.hits`, gated by PS5_GNM_DIAG like the other PS4-only wrappers.
//!
//! Classification (full table in task-4-report.md): all 37 are benign,
//! idempotent or status-returning calls from the companion/invitation/audio/
//! RTC/GNM-driver libraries. None has a shared implementation under its NID,
//! and none is an allocation/sync/data provider with a shared counterpart to
//! wrap, so each lands on minimal PS4-specific logic returning SCE_OK (0) —
//! the deliberate plausible value for these success/status paths, not a blind
//! default for a value-returning import.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const symbols = @import("../symbols.zig");
const hits = @import("ps4_mode").hits;

const Entry = struct { lib: []const u8, nid: []const u8 };

const entries = [_]Entry{
    .{ .lib = "libSceCompanionUtil", .nid = "IPN-FRSrafk" },
    .{ .lib = "libSceCompanionUtil", .nid = "xb1xlIhf0QY" },
    .{ .lib = "libSceCompanionUtil", .nid = "H1fYQd5lFAI" },
    .{ .lib = "libSceCompanionUtil", .nid = "cE5Msy11WhU" },
    .{ .lib = "libSceInvitationDialog", .nid = "9+g9iOq+7kg" },
    .{ .lib = "libSceInvitationDialog", .nid = "8XKR6wa64iQ" },
    .{ .lib = "libSceInvitationDialog", .nid = "B6HVJtDYxEE" },
    .{ .lib = "libSceInvitationDialog", .nid = "XvA5KS56wcs" },
    .{ .lib = "libSceInvitationDialog", .nid = "0zU0G+wiVLA" },
    .{ .lib = "libSceRtc", .nid = "NxEI1KByvCI" },
    .{ .lib = "libSceNgs2", .nid = "t9T0QM17Kvo" },
    .{ .lib = "libSceGnmDriver", .nid = "QhnyReteJ1M" },
    .{ .lib = "libSceGnmDriver", .nid = "jiItzS6+22g" },
    .{ .lib = "libSceGnmDriver", .nid = "aj3L-iaFmyk" },
    .{ .lib = "libSceGnmDriver", .nid = "W1Etj-jlW7Y" },
    .{ .lib = "libSceGnmDriver", .nid = "aPIZJTXC+cU" },
    .{ .lib = "libSceGnmDriver", .nid = "7qZVNgEu+SY" },
    .{ .lib = "libSceGnmDriver", .nid = "26PM5Mzl8zc" },
    .{ .lib = "libSceGnmDriver", .nid = "RU74kek-N0c" },
    .{ .lib = "libSceGnmDriver", .nid = "iCO804ZgzdA" },
    .{ .lib = "libSceGnmDriver", .nid = "PVT+fuoS9gU" },
    .{ .lib = "libSceGnmDriver", .nid = "UoYY0DWMC0U" },
    .{ .lib = "libSceGnmDriver", .nid = "H7-fgvEutM0" },
    .{ .lib = "libSceGnmDriver", .nid = "iBt3Oe00Kvc" },
    .{ .lib = "libSceGnmDriver", .nid = "qpGITzPE+Zc" },
    .{ .lib = "libSceGnmDriver", .nid = "b08AgtPlHPg" },
    .{ .lib = "libSceGnmDriver", .nid = "gObODli-OH8" },
    .{ .lib = "libSceGnmDriver", .nid = "+xuDhxlWRPg" },
    .{ .lib = "libSceGnmDriver", .nid = "f85orjx7qts" },
    .{ .lib = "libSceGnmDriver", .nid = "HHo1BAljZO8" },
    .{ .lib = "libSceGnmDriver", .nid = "jtkqXpAOY6w" },
    .{ .lib = "libSceGnmDriver", .nid = "u9YKpRRHe-M" },
    .{ .lib = "libSceGnmDriver", .nid = "4UFagYlfuAM" },
    .{ .lib = "libSceGnmDriver", .nid = "xeTLfxVIQO4" },
    .{ .lib = "libSceGnmDriver", .nid = "9thMn+uB1is" },
    .{ .lib = "libSceGnmDriver", .nid = "d88anrgNoKY" },
    .{ .lib = "libSceGnmDriver", .nid = "TLV4mswiZ4A" },
};

/// A per-import thunk: records the hit under this NID, answers SCE_OK.
fn stubFor(comptime e: Entry) abi.RawEntryPoint {
    const Impl = struct {
        fn call() callconv(abi.guest) u64 {
            hits.record(e.nid);
            return 0;
        }
    };
    return trace.wrap(e.nid, &Impl.call);
}

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    inline for (entries) |e| {
        try db.add(gpa, .{ .name = e.lib, .version = 1 }, .{ .name = e.lib }, .{
            .name = "ps4-terraria-stub",
            .function = stubFor(e),
            .id_override = e.nid,
        });
    }
}

test "every Terraria NID resolves under its exact PS4 identifier" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    inline for (entries) |e| {
        try std.testing.expect(db.findById(e.nid, .function) != null);
    }
}
