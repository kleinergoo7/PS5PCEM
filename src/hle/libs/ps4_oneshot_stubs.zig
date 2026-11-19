// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 OneShot first-frame import closure.
//!
//! These are the NIDs game-run enumerates as unresolved for OneShot, driven one
//! failing module at a time (the authoritative link queue; the larger
//! module-info MISS list is only a fallback and does not cover every PRX). Each
//! is registered under its exact PS4 NID via `id_override`, so no PS5 export is
//! shadowed. Every stub records its NID through `ps4_mode.hits`, gated by
//! PS5_GNM_DIAG like the other PS4-only wrappers.
//!
//! Classification (full table in task-5-report.md): every entry is a
//! status-returning or idempotent call with no HLE export under its PS4 NID, so
//! each lands on minimal PS4 logic returning SCE_OK — the deliberate plausible
//! success value for these paths, not a blind zero for a value-returning import.
//! The one exception, `hHrGoGoNf+s`, is the PS4 alias of the shared
//! `sceSysmoduleLoadModule`, whose implementation also reports SCE_OK.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const symbols = @import("../symbols.zig");
const errno = @import("../errno.zig");
const hits = @import("ps4_mode").hits;

const Entry = struct { lib: []const u8, nid: []const u8 };

const entries = [_]Entry{
    // libSceSysmodule — PS4 alias of the shared sceSysmoduleLoadModule
    // (registered under PS5 NID g8cM39EUZ6o); that shared implementation
    // reports success without mapping another image, so the alias does too.
    .{ .lib = "libSceSysmodule", .nid = "hHrGoGoNf+s" },

    // libSceAudio3d — status/idempotent audio-engine calls (init, listener and
    // source state, submit/render) from libfmod; no shared export under these
    // PS4 NIDs. SCE_OK is the plausible success value for each.
    .{ .lib = "libSceAudio3d", .nid = "Yq9bfUQ0uJg" },
    .{ .lib = "libSceAudio3d", .nid = "pZlOm1aF3aA" },
    .{ .lib = "libSceAudio3d", .nid = "YaaDbDwKpFM" },
    .{ .lib = "libSceAudio3d", .nid = "9tEwE0GV0qo" },
    .{ .lib = "libSceAudio3d", .nid = "HbxYY27lK6E" },
    .{ .lib = "libSceAudio3d", .nid = "lw0qrdSjZt8" },
    .{ .lib = "libSceAudio3d", .nid = "VEVhZ9qd4ZY" },
    .{ .lib = "libSceAudio3d", .nid = "1HXxo-+1qCw" },
    .{ .lib = "libSceAudio3d", .nid = "ucEsi62soTo" },

    // libSceGnmDriver — status/idempotent GNM driver command/state calls. Same
    // classification as the 26 GnmDriver NIDs stubbed for Terraria (43af013);
    // the shared GNM/AGC registry uses different PS5 NIDs, so these are PS4-only.
    .{ .lib = "libSceGnmDriver", .nid = "jRcI8VcgTz4" },
    .{ .lib = "libSceGnmDriver", .nid = "Ga6r7H6Y0RI" },
    .{ .lib = "libSceGnmDriver", .nid = "A+uGq+3KFtQ" },
    .{ .lib = "libSceGnmDriver", .nid = "byXlqupd8cE" },
    .{ .lib = "libSceGnmDriver", .nid = "tZCSL5ulnB4" },
    .{ .lib = "libSceGnmDriver", .nid = "fzJdEihTFV4" },
    .{ .lib = "libSceGnmDriver", .nid = "oL4hGI1PMpw" },
    .{ .lib = "libSceGnmDriver", .nid = "k7iGTvDQPLQ" },
    .{ .lib = "libSceGnmDriver", .nid = "nEyFbYUloIM" },
    .{ .lib = "libSceGnmDriver", .nid = "iFirFzgYsvw" },
    .{ .lib = "libSceGnmDriver", .nid = "dewXw5roLs0" },
    .{ .lib = "libSceGnmDriver", .nid = "6YRHhh5mHCs" },
    .{ .lib = "libSceGnmDriver", .nid = "R6z1xM3pW-w" },
    .{ .lib = "libSceGnmDriver", .nid = "5udAm+6boVg" },
    .{ .lib = "libSceGnmDriver", .nid = "ihxrbsoSKWc" },
    .{ .lib = "libSceGnmDriver", .nid = "Fa3x75OOLRA" },
    .{ .lib = "libSceGnmDriver", .nid = "UtObDRQiGbs" },
    .{ .lib = "libSceGnmDriver", .nid = "XiyzNZ9J4nQ" },
    .{ .lib = "libSceGnmDriver", .nid = "Fwvh++m9IQI" },
    .{ .lib = "libSceGnmDriver", .nid = "KnldROUkWJY" },
    .{ .lib = "libSceGnmDriver", .nid = "FFVZcCu3zWU" },
    .{ .lib = "libSceGnmDriver", .nid = "wED4ZXCFJT0" },
    .{ .lib = "libSceGnmDriver", .nid = "Kx-h-nWQJ8A" },
    .{ .lib = "libSceGnmDriver", .nid = "NfvOrNzy6sk" },
    .{ .lib = "libSceGnmDriver", .nid = "ffrNQOshows" },
    .{ .lib = "libSceGnmDriver", .nid = "EJapNl2+pgU" },
    .{ .lib = "libSceGnmDriver", .nid = "X9Omw9dwv5M" },
    .{ .lib = "libSceGnmDriver", .nid = "+AFvOEXrKJk" },
    .{ .lib = "libSceGnmDriver", .nid = "5uFKckiJYRM" },
    .{ .lib = "libSceGnmDriver", .nid = "cFCp0NX8wf0" },
    .{ .lib = "libSceGnmDriver", .nid = "Z43vKp5k7r0" },
    .{ .lib = "libSceGnmDriver", .nid = "HlTPoZ-oY7Y" },
    .{ .lib = "libSceGnmDriver", .nid = "GGsn7jMTxw4" },
    .{ .lib = "libSceGnmDriver", .nid = "ED9-Fjr8Ta4" },
    .{ .lib = "libSceGnmDriver", .nid = "thbPcG7E7qk" },
    .{ .lib = "libSceGnmDriver", .nid = "jHdPvIzlpKc" },
    .{ .lib = "libSceGnmDriver", .nid = "oYM+YzfCm2Y" },
    .{ .lib = "libSceGnmDriver", .nid = "4v+otIIdjqg" },
    .{ .lib = "libSceGnmDriver", .nid = "cUCo8OvArrw" },
    .{ .lib = "libSceGnmDriver", .nid = "yb2cRhagD1I" },
    .{ .lib = "libSceGnmDriver", .nid = "im2ZuItabu4" },
    .{ .lib = "libSceGnmDriver", .nid = "stDSYW2SBVM" },
    .{ .lib = "libSceGnmDriver", .nid = "nLM2i2+65hA" },
    .{ .lib = "libSceGnmDriver", .nid = "GNlx+y7xPdE" },
    .{ .lib = "libSceGnmDriver", .nid = "mLVL7N7BVBg" },
    .{ .lib = "libSceGnmDriver", .nid = "V31V01UiScY" },
    .{ .lib = "libSceGnmDriver", .nid = "Kl0Z3LH07QI" },
    .{ .lib = "libSceGnmDriver", .nid = "MYRtYhojKdA" },
    .{ .lib = "libSceGnmDriver", .nid = "0BzLGljcwBo" },

    // Second failing module (scePlayStation4.prx): status/idempotent service
    // calls with no HLE export under these PS4 NIDs. SCE_OK is the plausible
    // success value for each.
    // libSceCamera
    .{ .lib = "libSceCamera", .nid = "2G2C0nmd++M" },
    .{ .lib = "libSceCamera", .nid = "3i5MEzrC1pg" },
    .{ .lib = "libSceCamera", .nid = "9EpRYMy7rHU" },
    .{ .lib = "libSceCamera", .nid = "BHn83xrF92E" },
    .{ .lib = "libSceCamera", .nid = "HX5524E5tMY" },
    .{ .lib = "libSceCamera", .nid = "K7W7H4ZRwbc" },
    .{ .lib = "libSceCamera", .nid = "OMS9LlcrvBo" },
    .{ .lib = "libSceCamera", .nid = "ObIste7hqdk" },
    .{ .lib = "libSceCamera", .nid = "P-7MVfzvpsM" },
    .{ .lib = "libSceCamera", .nid = "QI8GVJUy2ZY" },
    .{ .lib = "libSceCamera", .nid = "RTDOsWWqdME" },
    .{ .lib = "libSceCamera", .nid = "VQ+5kAqsE2Q" },
    .{ .lib = "libSceCamera", .nid = "WVox2rwGuSc" },
    .{ .lib = "libSceCamera", .nid = "XqYRHc4aw3w" },
    .{ .lib = "libSceCamera", .nid = "a5xFueMZIMs" },
    .{ .lib = "libSceCamera", .nid = "bSKEi2PzzXI" },
    .{ .lib = "libSceCamera", .nid = "c6Fp9M1EXXc" },
    .{ .lib = "libSceCamera", .nid = "jMv40y2A23g" },
    .{ .lib = "libSceCamera", .nid = "k3zPIcgFNv0" },
    .{ .lib = "libSceCamera", .nid = "lhEIsHzB8r4" },
    .{ .lib = "libSceCamera", .nid = "p6n3Npi3YY4" },
    .{ .lib = "libSceCamera", .nid = "tslCukqFE+E" },
    .{ .lib = "libSceCamera", .nid = "wgBMXJJA6K4" },
    .{ .lib = "libSceCamera", .nid = "zrIUDKZx0iE" },
    // libSceGnmDriver
    .{ .lib = "libSceGnmDriver", .nid = "5SHGNwLXBV4" },
    .{ .lib = "libSceGnmDriver", .nid = "BgM3t3LvcNk" },
    .{ .lib = "libSceGnmDriver", .nid = "HzMN7ANqYEc" },
    .{ .lib = "libSceGnmDriver", .nid = "MBMa6EFu4Ko" },
    .{ .lib = "libSceGnmDriver", .nid = "Q7t4VEYLafI" },
    .{ .lib = "libSceGnmDriver", .nid = "RX7XCNSaL6I" },
    .{ .lib = "libSceGnmDriver", .nid = "SXw4dZEkgpA" },
    .{ .lib = "libSceGnmDriver", .nid = "hsZPf1lON7E" },
    .{ .lib = "libSceGnmDriver", .nid = "qGP74T5OWJc" },
    .{ .lib = "libSceGnmDriver", .nid = "rTIV11nMQuM" },
    // libScePlayGo
    .{ .lib = "libScePlayGo", .nid = "LosLlHOpNqQ" },
    // libSceRemoteplay
    .{ .lib = "libSceRemoteplay", .nid = "mrNh78tBpmg" },
    .{ .lib = "libSceRemoteplay", .nid = "xQeIryTX7dY" },
    // libSceSaveData
    .{ .lib = "libSceSaveData", .nid = "0z45PIH+SNI" },
    .{ .lib = "libSceSaveData", .nid = "RQOqDbk3bSU" },
    .{ .lib = "libSceSaveData", .nid = "VwadwBBBJ80" },
    .{ .lib = "libSceSaveData", .nid = "lU9YRFsgwSU" },
    // libSceScreenShot
    .{ .lib = "libSceScreenShot", .nid = "G7KlmIYFIZc" },
    .{ .lib = "libSceScreenShot", .nid = "ahHhOf+QNkQ" },
    // libSceSystemService
    .{ .lib = "libSceSystemService", .nid = "4imyVMxX5-8" },
    .{ .lib = "libSceSystemService", .nid = "eLWnPuja+Y8" },
    // libSceUserService
    .{ .lib = "libSceUserService", .nid = "lUoqwTQu4Go" },
    // libSceVideoRecording
    .{ .lib = "libSceVideoRecording", .nid = "KHvkPQJDMLk" },
    .{ .lib = "libSceVideoRecording", .nid = "OOFxrMY+mfI" },
    .{ .lib = "libSceVideoRecording", .nid = "bGYkY6q3bIw" },
    .{ .lib = "libSceVideoRecording", .nid = "fZJQzFK4Gv4" },
    .{ .lib = "libSceVideoRecording", .nid = "s28dalBwp2g" },
    .{ .lib = "libSceVideoRecording", .nid = "tWoe9IlGAhs" },
};

/// A per-import thunk: records the hit under this NID, answers SCE_OK.
fn stubFor(comptime e: Entry) abi.RawEntryPoint {
    const Impl = struct {
        fn call() callconv(abi.guest) u64 {
            hits.record(e.nid);
            return errno.ok;
        }
    };
    return trace.wrap(e.nid, &Impl.call);
}

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    inline for (entries) |e| {
        try db.add(gpa, .{ .name = e.lib, .version = 1 }, .{ .name = e.lib }, .{
            .name = "ps4-oneshot-stub",
            .function = stubFor(e),
            .id_override = e.nid,
        });
    }
}

test "every OneShot NID resolves under its exact PS4 identifier" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    inline for (entries) |e| {
        try std.testing.expect(db.findById(e.nid, .function) != null);
    }
}
