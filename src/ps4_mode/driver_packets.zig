// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! GNM driver packet emission: default hardware state + validation aliases.
//!
//! PS4 titles expect the driver to emit a default-state preamble (legacy
//! hardware/context init packets) before their own command buffers run.
//! This module builds that preamble as raw dwords the caller submits through
//! the normal command-stream path, plus the submit-readiness / flip-wait
//! packet helpers the driver aliases expose.

const std = @import("std");

/// Packet ids for the driver preamble (GNM private range, dword header with
/// op in [31..24] and body length in [23..16], matching gnm_packets.zig).
pub const Op = enum(u8) {
    hw_init = 0x10,
    context_init = 0x11,
    submit_ready = 0x12,
    flip_wait = 0x13,
    _,
};

fn header(op: Op, body_words: u8) u32 {
    return (@as(u32, @intFromEnum(op)) << 24) | (@as(u32, body_words) << 16);
}

/// Emit the default-state preamble into `out`. Returns dwords written.
/// Layout: hw_init[4], context_init[2], submit_ready[0].
pub fn emitDefaultState(out: []u32) usize {
    const need = 3 + 4 + 3 + 2 + 1;
    if (out.len < need) return 0;
    var n: usize = 0;
    out[n] = header(.hw_init, 4);
    n += 1;
    out[n] = 0x0000_0001; // hardware revision selector
    n += 1;
    out[n] = 0x0000_0000; // reserved
    n += 1;
    out[n] = 0x0000_0000; // reserved
    n += 1;
    out[n] = 0x0000_0000; // reserved
    n += 1;
    out[n] = header(.context_init, 2);
    n += 1;
    out[n] = 0x0000_0003; // color + depth context enable mask
    n += 1;
    out[n] = 0x0000_0001; // shader engine count
    n += 1;
    out[n] = header(.submit_ready, 0);
    n += 1;
    return n;
}

/// Emit a flip-wait packet (guest blocks until flip `label` completes).
pub fn emitFlipWait(out: []u32, label: u32) usize {
    if (out.len < 2) return 0;
    out[0] = header(.flip_wait, 1);
    out[1] = label;
    return 2;
}

/// Driver validation alias: true when the preamble in `dwords` starts with a
/// well-formed hw_init packet (cheap check before full translation).
pub fn looksLikeDefaultState(dwords: []const u32) bool {
    if (dwords.len < 6) return false;
    const op: u8 = @intCast((dwords[0] >> 24) & 0xff);
    const body: u8 = @intCast((dwords[0] >> 16) & 0xff);
    return op == @intFromEnum(Op.hw_init) and body == 4;
}
