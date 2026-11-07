// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! GNM command-buffer translation.
//!
//! PS4 GNM writes command buffers that look like PM4 but carry Sony-private
//! packet ids and a different register layout. SharpEmu's GNM mode translates
//! those packets into its shared GPU work items; this module is the PS5PCEM
//! equivalent at the decode level: walk a dword stream safely and emit neutral
//! `WorkItem`s the existing gpu/ executor can later consume. It performs no
//! rendering itself.

const std = @import("std");

pub const Error = error{
    Truncated,
    TooManyItems,
};

/// GNM packet ids observed in traces (subset; unknown ids pass through as
/// `.unsupported` instead of aborting the stream, matching SharpEmu's
/// "record nothing / skip" policy for packets it does not lower yet).
pub const Op = enum(u8) {
    nop = 0x00,
    draw_index = 0x01,
    draw_index_auto = 0x02,
    dispatch_direct = 0x03,
    write_data = 0x04,
    set_sh_reg = 0x05,
    set_context_reg = 0x06,
    event_write_eop = 0x07,
    dma_data = 0x08,
    _,

    pub fn label(self: Op) []const u8 {
        return switch (self) {
            .nop => "nop",
            .draw_index => "draw_index",
            .draw_index_auto => "draw_index_auto",
            .dispatch_direct => "dispatch_direct",
            .write_data => "write_data",
            .set_sh_reg => "set_sh_reg",
            .set_context_reg => "set_context_reg",
            .event_write_eop => "event_write_eop",
            .dma_data => "dma_data",
            else => "unsupported",
        };
    }
};

/// Neutral work item handed to the shared backend.
pub const WorkItem = union(enum) {
    nop: u32, // dword count skipped
    draw: Draw,
    dispatch: Dispatch,
    barrier: Barrier,
    set_reg: SetReg,
    unsupported: u8, // raw op id

    pub const Draw = struct {
        index_count: u32,
        vgt_dma_index_type: u8, // 0 = 16-bit, 1 = 32-bit
    };
    pub const Dispatch = struct { x: u16, y: u16, z: u16 };
    pub const Barrier = struct { kind: u8 };
    pub const SetReg = struct { base: u16, count: u8 };
};

/// Header word layout: [31..24]=op, [23..16]=body dwords, [15..0]=reserved.
pub fn decodeHeader(word: u32) struct { op: u8, body: u8 } {
    return .{
        .op = @intCast((word >> 24) & 0xff),
        .body = @intCast((word >> 16) & 0xff),
    };
}

pub fn encodeHeader(op: u8, body_words: u8) u32 {
    return (@as(u32, op) << 24) | (@as(u32, body_words) << 16);
}

/// Translate at most `out.len` items. Returns item count. Stops cleanly on a
/// truncated tail (caller decides whether that is fatal).
pub fn translateStream(dwords: []const u32, out: []WorkItem) Error!usize {
    var pos: usize = 0;
    var n: usize = 0;
    while (pos < dwords.len) {
        if (n >= out.len) return Error.TooManyItems;
        const h = decodeHeader(dwords[pos]);
        const body_len: usize = h.body;
        if (pos + 1 + body_len > dwords.len) return Error.Truncated;
        const body = dwords[pos + 1 .. pos + 1 + body_len];
        // Map manually with a plain switch (no @typeInfo: stable across Zig versions).
        const real_op: Op = switch (h.op) {
            0x00 => .nop,
            0x01 => .draw_index,
            0x02 => .draw_index_auto,
            0x03 => .dispatch_direct,
            0x04 => .write_data,
            0x05 => .set_sh_reg,
            0x06 => .set_context_reg,
            0x07 => .event_write_eop,
            0x08 => .dma_data,
            else => @enumFromInt(h.op),
        };
        out[n] = switch (real_op) {
            .nop => .{ .nop = @intCast(1 + body_len) },
            .draw_index => .{ .draw = .{
                .index_count = if (body.len > 0) body[0] else 0,
                .vgt_dma_index_type = if (body.len > 1) @intCast(body[1] & 1) else 0,
            } },
            .draw_index_auto => .{ .draw = .{
                .index_count = if (body.len > 0) body[0] else 0,
                .vgt_dma_index_type = 1,
            } },
            .dispatch_direct => .{ .dispatch = .{
                .x = if (body.len > 0) @intCast(body[0] & 0xffff) else 1,
                .y = if (body.len > 1) @intCast(body[1] & 0xffff) else 1,
                .z = if (body.len > 2) @intCast(body[2] & 0xffff) else 1,
            } },
            .event_write_eop => .{ .barrier = .{ .kind = 1 } },
            .dma_data, .write_data => .{ .barrier = .{ .kind = 2 } },
            .set_sh_reg, .set_context_reg => .{ .set_reg = .{
                .base = if (body.len > 0) @intCast(body[0] & 0xffff) else 0,
                .count = @intCast(if (body.len > 0) body.len - 1 else 0),
            } },
            _ => .{ .unsupported = h.op },
        };
        n += 1;
        pos += 1 + body_len;
    }
    return n;
}

test "draw and dispatch translate" {
    var stream = [_]u32{
        encodeHeader(0x01, 2), 36, 1, // draw_index count=36 idx32
        encodeHeader(0x03, 3), 8, 4, 1, // dispatch 8x4x1
        encodeHeader(0x00, 0), // nop
    };
    var out: [8]WorkItem = undefined;
    const n = try translateStream(&stream, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 36), out[0].draw.index_count);
    try std.testing.expectEqual(@as(u16, 8), out[1].dispatch.x);
    try std.testing.expectEqual(@as(u16, 4), out[1].dispatch.y);
    try std.testing.expectEqual(@as(u32, 1), out[2].nop);
}

test "unknown op passes through as unsupported" {
    var stream = [_]u32{ encodeHeader(0xFE, 0) };
    var out: [4]WorkItem = undefined;
    const n = try translateStream(&stream, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0xFE), out[0].unsupported);
}

test "truncated tail reports cleanly" {
    var stream = [_]u32{ encodeHeader(0x03, 3), 8 };
    var out: [4]WorkItem = undefined;
    try std.testing.expectError(Error.Truncated, translateStream(&stream, &out));
}
