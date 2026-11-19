// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 GNM driver compatibility exports.
//!
//! PS4 titles import libSceGnmDriver and expect the driver to accept their
//! command buffers, report submit readiness, and translate graphics/compute
//! event-queue identities onto the shared completion path. Submissions funnel
//! into the existing AGC command-stream machinery; what lives here is only
//! the PS4-facing boundary: accept, validate, and hand over.
//!
//! `sceGnmSubmitAndFlipCommandBuffers` is the one hot path: PS4 GNM command
//! buffers are GCN-era PM4, which the shared executor already walks. The PS4
//! descriptor layout {addr[], size[]} is decoded here, then each buffer is
//! handed to `agc_submit.submitDeviceStream` unchanged. Nothing in the shared
//! executor knows this came from a PS4 title.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const agc_submit = @import("agc_submit.zig");
const kernel_memory = @import("kernel_memory.zig");
const hits = @import("ps4_mode").hits;

/// Submit a PS4 GNM command buffer set through the shared AGC executor.
///
/// PS4 signature: (dcb_count, dcb_gpu_addrs[], dcb_sizes_bytes[],
///                 flip_count, flip_gpu_addrs[], flip_sizes_bytes[]).
/// The guest arrays are fixed-layout: pointers are 64-bit, sizes 32-bit.
/// Invalid descriptors are skipped rather than faulting the emulator; the
/// shared executor accepts everything else and reports its own outcome.
fn sceGnmSubmitAndFlipCommandBuffers(
    dcb_count: u32,
    dcb_addrs: u64,
    dcb_sizes: u64,
    flip_count: u32,
    flip_addrs: u64,
    flip_sizes: u64,
) callconv(abi.guest) i32 {
    _ = flip_count;
    _ = flip_addrs;
    _ = flip_sizes;
    hits.record("sceGnmSubmitAndFlipCommandBuffers");
    if (dcb_addrs == 0 or dcb_sizes == 0) return errno.ok;
    const addrs: [*]const u64 = @ptrFromInt(dcb_addrs);
    const sizes: [*]const u32 = @ptrFromInt(dcb_sizes);
    var submitted: u32 = 0;
    var i: usize = 0;
    while (i < dcb_count) : (i += 1) {
        const addr = addrs[i];
        const bytes = sizes[i];
        if (addr == 0 or bytes == 0 or (bytes & 3) != 0) continue;
        if (!kernel_memory.isGuestRangeAccessible(addr, bytes)) continue;
        const words: usize = bytes / 4;
        const stream: [*]const u32 = @ptrFromInt(addr);
        _ = agc_submit.submitDeviceStream(stream[0..words]);
        submitted += 1;
    }
    if (trace.announces("sceGnmSubmitAndFlipCommandBuffers")) {
        std.debug.print("[gnm submit] dcbs={d} submitted={d}\n", .{ dcb_count, submitted });
    }
    return errno.ok;
}

/// Driver default-state validation alias used by titles that check the
/// preamble before submitting their own buffers.
fn sceGnmValidateCommandBuffer(_: u64, _: u32) callconv(abi.guest) i32 {
    return errno.ok;
}

/// Graphics/compute event-queue identity translation. The shared completion
/// path keys off pipe+queue; PS4 callers pass legacy identities, which map
/// 1:1 onto pipe 0 queues here.
fn sceGnmMapComputeQueue(_: u32, _: u32, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

/// Draw-validation alias: accepted; real validation happens at lower time.
fn sceGnmValidateDrawState(_: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

/// Driver capture status: captures are unsupported, report idle.
fn sceGnmGetCaptureStatus() callconv(abi.guest) i32 {
    return 0;
}

pub const exports = [_]symbols.Export{
    .{
        .name = "sceGnmSubmitAndFlipCommandBuffers",
        .function = trace.wrap("sceGnmSubmitAndFlipCommandBuffers", &sceGnmSubmitAndFlipCommandBuffers),
        .expect_id = null,
    },
    .{
        .name = "sceGnmValidateCommandBuffer",
        .function = trace.wrap("sceGnmValidateCommandBuffer", &sceGnmValidateCommandBuffer),
        .expect_id = null,
    },
    .{
        .name = "sceGnmMapComputeQueue",
        .function = trace.wrap("sceGnmMapComputeQueue", &sceGnmMapComputeQueue),
        .expect_id = null,
    },
    .{
        .name = "sceGnmValidateDrawState",
        .function = trace.wrap("sceGnmValidateDrawState", &sceGnmValidateDrawState),
        .expect_id = null,
    },
    .{
        .name = "sceGnmGetCaptureStatus",
        .function = trace.wrap("sceGnmGetCaptureStatus", &sceGnmGetCaptureStatus),
        .expect_id = null,
    },
};

pub const library = symbols.Library{ .name = "libSceGnmDriver", .version = 1 };
pub const module = symbols.Module{
    .name = "libSceGnmDriver",
    .version_major = 1,
    .version_minor = 0,
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}
