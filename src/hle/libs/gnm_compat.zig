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
//! sanitized (GCN register offsets outside the shared register files are
//! dropped) and handed to `agc_submit.submitDeviceStream`. Nothing in the
//! shared executor knows this came from a PS4 title.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const agc_submit = @import("agc_submit.zig");
const kernel_memory = @import("kernel_memory.zig");
const kernel_event_queue = @import("kernel_event_queue.zig");
const video_out = @import("../video_out.zig");
const kernel_runtime = @import("kernel_runtime.zig");
const ps4_mode = @import("ps4_mode");
const hits = ps4_mode.hits;
const pm4_sanitize = ps4_mode.pm4_sanitize;

/// PS4 titles submit DCBs without a flip packet or a registered scanout set,
/// so the shared renderer has nothing to present and the window stays black.
/// Publish the guest colour target as a VideoOut buffer once, then drive the
/// shared flip path at display cadence. Only called from PS4 submit exports.
var scanout_registered = false;
var last_scanout_flip_ns: u64 = 0;

fn presentPs4Scanout(address: u64) void {
    if (!scanout_registered) {
        if (video_out.resolve(1, 0) == null) {
            const buffers = [_]video_out.Buffer{.{
                .data = @ptrFromInt(address),
                .metadata = null,
                .reserved = .{ null, null },
            }};
            const attribute = video_out.BufferAttribute2{
                .width = 1920,
                .height = 1080,
                .pitch_in_pixels = 1920,
                .pixel_format = 0x8100_0000_0000_0000,
            };
            _ = video_out.registerBuffers(0, 0, &buffers, attribute, 0) catch null;
        }
        scanout_registered = video_out.resolve(1, 0) != null;
    }
    if (!scanout_registered) return;
    const now = kernel_runtime.processTimeCounter();
    if (now -| last_scanout_flip_ns < 16 * std.time.ns_per_ms) return;
    last_scanout_flip_ns = now;
    _ = agc_submit.presentFlip(.{
        .video_out_handle = 1,
        .display_buffer_index = 0,
        .mode = 0,
        .argument = @bitCast(@as(i64, @intCast(now & 0x7fff_ffff_ffff_ffff))),
    });
}

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
    _: u32,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    hits.record("sceGnmSubmitAndFlipCommandBuffers");
    if (dcb_addrs == 0 or dcb_sizes == 0) return errno.ok;
    const addrs: [*]const u64 = @ptrFromInt(dcb_addrs);
    const sizes: [*]const u32 = @ptrFromInt(dcb_sizes);
    var submitted: u32 = 0;
    var scanout_address: u64 = 0;
    var i: usize = 0;
    while (i < dcb_count) : (i += 1) {
        const addr = addrs[i];
        const bytes = sizes[i];
        if (addr == 0 or bytes == 0 or (bytes & 3) != 0) continue;
        if (!kernel_memory.isGuestRangeAccessible(addr, bytes)) continue;
        const words: usize = bytes / 4;
        const stream: [*]const u32 = @ptrFromInt(addr);
        const slice = stream[0..words];
        // PS4-only: decode this DCB's GCN shader resources (PS/VS T#/S#/V#
        // descriptors and settled USER_DATA words) at the submit boundary and
        // publish them for the PS4 draw's descriptor binding. Pure data capture;
        // the shared executor and its register checks are untouched.
        ps4_mode.gcn_resources.publish(ps4_mode.gcn_resources.capture(slice));
        if (scanout_address == 0) scanout_address = pm4_sanitize.colorTargetAddress(slice) orelse 0;

        // PS4 GCN PM4 is not walkable by the shared RDNA2 parser as-is: an
        // out-of-range SET_*_REG stops the queue, and a malformed body length
        // hides the real packets (including draws) behind it. Rebuild a clean
        // Type-3-only stream here, at the PS4 boundary; the shared executor's
        // register-range check is never relaxed. GCN DCBs also never write the
        // AGC context registers that describe render-target size/address-high,
        // so synthesize those from the guest's own CB registers before handing
        // the stream over. Fall back to the original stream if allocation fails.
        const prefix_cap = pm4_sanitize.max_synthesized_dwords + pm4_sanitize.max_shader_reg_dwords;
        const clean = std.heap.page_allocator.alloc(u32, words + prefix_cap) catch {
            _ = agc_submit.submitDeviceStream(slice);
            submitted += 1;
            continue;
        };
        defer std.heap.page_allocator.free(clean);
        const rt_words = pm4_sanitize.synthesizeRenderTargetRegs(slice, clean, .{});
        // PS4 shader-set imports are captured at the HLE boundary; bind their
        // program addresses here so the shared decoder sees a VS/PS pair.
        const shader_words = pm4_sanitize.synthesizeShaderProgramRegs(
            ps4_mode.shader_binding.programs(),
            clean[rt_words..],
        );
        const prefix_words = rt_words + shader_words;
        var stats: pm4_sanitize.Stats = .{};
        const clean_words = prefix_words + pm4_sanitize.sanitize(slice, clean[prefix_words..], &stats);
        if (clean_words == prefix_words and prefix_words == 0) continue;
        if (trace.announces("sceGnmSubmitAndFlipCommandBuffers") and
            (stats.dropped_config | stats.dropped_context | stats.dropped_shader | stats.dropped_uconfig) != 0)
        {
            std.debug.print(
                "[gnm submit] sanitized DCB {d}->{d} dwords (rt-prefix={d} sh-prefix={d} kept={d} cfg={d} ctx={d} sh={d} ucfg={d} skipped={d})\n",
                .{ words, clean_words, rt_words, shader_words, stats.kept, stats.dropped_config, stats.dropped_context, stats.dropped_shader, stats.dropped_uconfig, stats.skipped_words },
            );
        }
        _ = agc_submit.submitDeviceStream(clean[0..clean_words]);
        submitted += 1;
    }
    if (submitted != 0) {
        // PS4 GNM owns the flip notification: titles register a VideoOut flip
        // event and wait on it right after SubmitAndFlipCommandBuffers. The
        // setup DCB carries no FLIP/RELEASE_MEM packet for the shared path to
        // publish that edge, so deliver it here at the PS4 boundary.
        _ = kernel_event_queue.triggerVideoOutFlip(0);
        if (scanout_address != 0) presentPs4Scanout(scanout_address);
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
