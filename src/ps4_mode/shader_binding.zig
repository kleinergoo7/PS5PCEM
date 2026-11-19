// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4-only shader-binding state.
//!
//! Terraria binds its GCN shaders through `sceGnmSetPsShader` /
//! `sceGnmSetVsShader`. Those were no-op stubs, so the shared executor saw no
//! graphics program at all. The PS4-keyed exports record the guest shader
//! pointer here; at the GNM submit boundary `pm4_sanitize` turns it into the
//! SH program-address registers the shared pipeline reads. The recorded binary
//! is GCN and cannot be decoded by the shared AGC path, so PS4 draws are
//! replayed with the fixed-color probe shader (see the Vulkan backend).
//! Nothing here is reachable unless a PS4 title imports those NIDs.

const std = @import("std");
const hits = @import("hits.zig");
const pm4_sanitize = @import("pm4_sanitize.zig");

var pixel_shader: u64 = 0;
var vertex_shader: u64 = 0;

pub fn setPixelShader(pointer: u64) void {
    @atomicStore(u64, &pixel_shader, pointer, .monotonic);
    hits.record("sceGnmSetPsShader");
}

pub fn setVertexShader(pointer: u64) void {
    @atomicStore(u64, &vertex_shader, pointer, .monotonic);
    hits.record("sceGnmSetVsShader");
}

pub fn programs() pm4_sanitize.ShaderPrograms {
    return .{
        .pixel = @atomicLoad(u64, &pixel_shader, .monotonic),
        .vertex = @atomicLoad(u64, &vertex_shader, .monotonic),
    };
}

pub fn reset() void {
    @atomicStore(u64, &pixel_shader, 0, .monotonic);
    @atomicStore(u64, &vertex_shader, 0, .monotonic);
}

test "records shader pointers for the PS4 submit boundary" {
    reset();
    defer reset();

    setPixelShader(0x1234_5600);
    setVertexShader(0x789a_bc00);
    const pair = programs();
    try std.testing.expectEqual(@as(u64, 0x1234_5600), pair.pixel);
    try std.testing.expectEqual(@as(u64, 0x789a_bc00), pair.vertex);

    reset();
    try std.testing.expectEqual(@as(u64, 0), programs().pixel);
}
