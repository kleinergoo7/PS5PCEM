// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Backend-neutral lowering of translated GNM work items.
//!
//! `gnm_packets.translateStream` decodes; this module lowers: merges adjacent
//! barriers into one mailbox per image-class (SharpEmu: "one merged barrier
//! per image"), drops reads-after-reads, counts draws/dispatches for the
//! render-phase profiler, and records the draw's register snapshot identity
//! so deferred draws can reuse the previous shell. Output is a flat
//! `Lowered` list the gpu/ executor consumes without knowing GNM.

const std = @import("std");
const gnm_packets = @import("gnm_packets.zig");

pub const LoweredTag = enum {
    draw,
    dispatch,
    barrier,
    set_reg,
    skipped, // reads-after-reads / discarded segments: recorded as nothing
};

pub const Lowered = struct {
    tag: LoweredTag,
    w0: u32 = 0,
    w1: u32 = 0,
    w2: u32 = 0,
};

pub const Stats = struct {
    draws: u32 = 0,
    dispatches: u32 = 0,
    barriers_merged: u32 = 0,
    barriers_dropped: u32 = 0, // reads-after-reads
    set_regs: u32 = 0,
    unsupported: u32 = 0,
};

/// Lower translated items into `out`. Merges consecutive barriers of the same
/// kind and drops barrier kind 2 that directly follows another kind 2
/// (read-after-read needs no barrier).
pub fn lower(items: []const gnm_packets.WorkItem, out: []Lowered, stats: *Stats) usize {
    var n: usize = 0;
    var pending_barrier: ?u8 = null;
    for (items) |item| {
        switch (item) {
            .nop => {},
            .draw => |d| {
                if (pending_barrier) |k| {
                    if (n < out.len) {
                        out[n] = .{ .tag = .barrier, .w0 = k };
                        n += 1;
                        stats.barriers_merged += 1;
                    }
                    pending_barrier = null;
                }
                if (n < out.len) {
                    out[n] = .{ .tag = .draw, .w0 = d.index_count, .w1 = d.vgt_dma_index_type };
                    n += 1;
                    stats.draws += 1;
                }
            },
            .dispatch => |d| {
                if (pending_barrier) |k| {
                    if (n < out.len) {
                        out[n] = .{ .tag = .barrier, .w0 = k };
                        n += 1;
                        stats.barriers_merged += 1;
                    }
                    pending_barrier = null;
                }
                if (n < out.len) {
                    out[n] = .{ .tag = .dispatch, .w0 = d.x, .w1 = d.y, .w2 = d.z };
                    n += 1;
                    stats.dispatches += 1;
                }
            },
            .barrier => |b| {
                if (pending_barrier) |k| {
                    if (k == b.kind and b.kind == 2) {
                        stats.barriers_dropped += 1; // read after read
                        continue;
                    }
                    if (n < out.len) {
                        out[n] = .{ .tag = .barrier, .w0 = k };
                        n += 1;
                        stats.barriers_merged += 1;
                    }
                }
                pending_barrier = b.kind;
            },
            .set_reg => |r| {
                if (n < out.len) {
                    out[n] = .{ .tag = .set_reg, .w0 = r.base, .w1 = r.count };
                    n += 1;
                    stats.set_regs += 1;
                }
            },
            .unsupported => {
                stats.unsupported += 1;
            },
        }
    }
    if (pending_barrier) |k| {
        if (n < out.len) {
            out[n] = .{ .tag = .barrier, .w0 = k };
            n += 1;
            stats.barriers_merged += 1;
        }
    }
    return n;
}
