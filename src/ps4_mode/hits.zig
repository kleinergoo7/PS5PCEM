// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4-only wrapper hit counters.
//!
//! Every new PS4 wrapper/stub records its own name; `report` renders the
//! accumulated counts for the PS5_GNM_DIAG diagnostics gate. Kept here so the
//! PS5 instrumentation in src/hle/trace.zig stays untouched. Names are borrowed
//! static strings, the same way a trace thunk borrows its entry-point name.

const std = @import("std");
const game_hook = @import("game_hook.zig");

/// How many distinct wrapper names can be counted at once. Enough for a title's
/// MISS set while staying a few cache lines of fixed storage.
pub const capacity: usize = 128;

const Slot = struct {
    name: []const u8 = &.{},
    count: u64 = 0,
};

var slots: [capacity]Slot = [_]Slot{.{}} ** capacity;

/// Recording is gated by PS5_GNM_DIAG: game_run seeds that flag into
/// `game_hook` before any PS4 wrapper runs. Read once on first use; `setEnabled`
/// overrides it (tests, or a caller that already parsed the flag).
var enabled: ?bool = null;

fn isEnabled() bool {
    return enabled orelse blk: {
        const on = game_hook.configFromEnv().diag;
        enabled = on;
        break :blk on;
    };
}

pub fn setEnabled(value: bool) void {
    enabled = value;
}

/// Count one hit of `name`. Empty names are ignored; a new name claims the next
/// free slot. Beyond capacity the hit is dropped rather than displacing data.
pub fn record(name: []const u8) void {
    if (name.len == 0 or !isEnabled()) return;
    for (&slots) |*slot| {
        if (std.mem.eql(u8, slot.name, name)) {
            slot.count +%= 1;
            return;
        }
    }
    for (&slots) |*slot| {
        if (slot.name.len == 0) {
            slot.name = name;
            slot.count = 1;
            return;
        }
    }
}

/// Render one `"<name> <count>\n"` line per non-empty slot into `buf`, returning
/// the bytes written. Stops cleanly when `buf` runs out of room.
pub fn report(buf: []u8) []const u8 {
    var used: usize = 0;
    for (slots) |slot| {
        if (slot.name.len == 0) continue;
        const line = std.fmt.bufPrint(buf[used..], "{s} {d}\n", .{ slot.name, slot.count }) catch break;
        used += line.len;
    }
    return buf[0..used];
}

/// Forget all counts so a later report starts from an empty table.
pub fn reset() void {
    for (&slots) |*slot| slot.* = .{};
}

test "two records of one name report count 2, and reset clears it" {
    setEnabled(true);
    defer reset();

    reset();
    record("sceKernelAllocateMemory");
    record("sceKernelAllocateMemory");

    var buf: [512]u8 = undefined;
    const text = report(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "sceKernelAllocateMemory 2") != null);

    reset();
    const cleared = report(&buf);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "sceKernelAllocateMemory") == null);
}
