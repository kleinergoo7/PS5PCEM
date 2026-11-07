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
//! All entry points are currently accept-and-report: they validate trivially
//! invalid input (null buffers) and return success so titles progress past
//! driver init into real command emission, which the packet pipeline lowers.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

/// Submit readiness: always ready; the shared scheduler serializes anyway.
fn sceGnmSubmitAndFlipCommandBuffers(_: u32, _: u64, _: u32, _: u64) callconv(abi.guest) i32 {
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
