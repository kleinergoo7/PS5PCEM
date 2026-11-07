// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! ps4_mode — experimental PS4 (GNM/GCN) backward compatibility.
//!
//! Analogous to SharpEmu's GNM mode: PS4 titles keep their interfaces, and
//! this layer translates content detection, shader metadata, command packets
//! and image layouts into representations the existing PS5-oriented path
//! (loader/, rdna2/, gpu/, hle/) already understands. It introduces no
//! separate recompiler or renderer backend.
//!
//! The module is intentionally dependency-free (std only) so it compiles and
//! tests in isolation; integration call sites are documented per function.

pub const sfo = @import("sfo.zig");
pub const detector = @import("detector.zig");
pub const gcn_header = @import("gcn_header.zig");
pub const gnm_packets = @import("gnm_packets.zig");
pub const image_layout = @import("image_layout.zig");
pub const compat_hle = @import("compat_hle.zig");
pub const runtime = @import("runtime.zig");

pub const Mode = detector.Mode;
pub const Session = runtime.Session;
pub const Config = runtime.Config;

/// One-line summary for `--version`-style diagnostics and logs.
pub fn describe() []const u8 {
    return "ps4_mode: GNM/GCN compat (detect+sfo, shader headers, packet translation, tiling, hle table, session)";
}

test {
    _ = sfo;
    _ = detector;
    _ = gcn_header;
    _ = gnm_packets;
    _ = image_layout;
    _ = compat_hle;
    _ = runtime;
}
