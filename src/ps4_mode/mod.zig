// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Compatibility shim: the original scaffold imported `ps4_mode/mod.zig`.
//! The canonical module root is now `root.zig`; this file re-exports it so
//! existing imports keep compiling.

pub usingnamespace @import("root.zig");
