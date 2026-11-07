// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! One-call session bootstrap + packet pipeline for embedders.
//!
//! `launch.zig` fills a session; `gnm_packets` + `gpu_translate` decode and
//! lower; this file chains the three: detect → translate → lower, returning
//! the lowered list and stats. The gpu/ executor then consumes `Lowered`
//! without importing anything PS4-specific.

const std = @import("std");
const detector = @import("detector.zig");
const runtime = @import("runtime.zig");
const launch = @import("launch.zig");
const gnm_packets = @import("gnm_packets.zig");
const gpu_translate = @import("gpu_translate.zig");
const driver_packets = @import("driver_packets.zig");

pub const PipelineStats = struct {
    items: usize = 0,
    lowered: usize = 0,
    inner: gpu_translate.Stats = .{},
};

/// Bootstrap the session, then translate + lower one GNM command buffer.
/// Scratch buffers are caller-owned (no allocation): `items` holds decoded
/// work items, `lowered_out` the backend list.
pub fn runBuffer(
    session: *runtime.Session,
    param_sfo: ?[]const u8,
    eboot: ?[]const u8,
    cfg: runtime.Config,
    dwords: []const u32,
    items: []gnm_packets.WorkItem,
    lowered_out: []gpu_translate.Lowered,
    stats: *PipelineStats,
) void {
    launch.bootstrap(session, param_sfo, eboot, cfg);
    stats.items = gnm_packets.translateStream(dwords, items) catch 0;
    stats.lowered = gpu_translate.lower(items[0..stats.items], lowered_out, &stats.inner);
}

/// Submit the driver default-state preamble through the same pipeline.
/// Returns lowered count (0 when scratch is too small).
pub fn runDefaultState(
    lowered_out: []gpu_translate.Lowered,
    stats: *PipelineStats,
) usize {
    var words: [16]u32 = undefined;
    const n = driver_packets.emitDefaultState(&words);
    if (n == 0) return 0;
    var items: [16]gnm_packets.WorkItem = undefined;
    // The preamble uses driver-private ops: unknown ids land as `unsupported`
    // and are counted, never fatal.
    stats.items = gnm_packets.translateStream(words[0..n], &items) catch 0;
    stats.lowered = gpu_translate.lower(items[0..stats.items], lowered_out, &stats.inner);
    _ = detector.Mode.ps4_gnm;
    return stats.lowered;
}
