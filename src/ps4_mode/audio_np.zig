// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4 audio / NP / savedata layout adapters.
//!
//! Same-concept-different-layout services: ATRAC9 with RIFF headers + gapless
//! trim, NP identifiers in the PS4 layout, offline TUS completion, and save
//! progress dialogs that stay open until the guest closes them. Pure
//! transforms over guest structs; the players/services themselves are reused.

const std = @import("std");

/// RIFF ATRAC9 chunk header (first 12 bytes of decoder input).
pub const RiffHeader = struct {
    is_riff: bool,
    data_offset: u32, // start of audio payload
    data_len: u32,
};

pub fn parseRiff(input: []const u8) RiffHeader {
    if (input.len < 12) return .{ .is_riff = false, .data_offset = 0, .data_len = @intCast(input.len) };
    if (!std.mem.eql(u8, input[0..4], "RIFF")) return .{ .is_riff = false, .data_offset = 0, .data_len = @intCast(input.len) };
    const size = std.mem.readInt(u32, input[4..8], .little);
    const off: u32 = 12;
    return .{ .is_riff = true, .data_offset = off, .data_len = @min(size, @as(u32, @intCast(input.len)) -| off) };
}

/// Gapless trim: leading/trailing samples the decoder must drop so loops are
/// seamless. Returns (keep_start, keep_len) in samples.
pub fn gaplessWindow(total_samples: u32, leading_trim: u32, trailing_trim: u32) struct { start: u32, len: u32 } {
    const start = @min(leading_trim, total_samples);
    const len = total_samples -| start -| trailing_trim;
    return .{ .start = start, .len = len };
}

/// PS4 NP ID layout → internal view. PS4 packs the communication id +
/// account id differently; normalize here.
pub const NpIdView = struct {
    comm_id: [10]u8, // e.g. "CUSA00001"
    account_id: u64,
};

pub fn normalizeNpId(comm_id_raw: []const u8, account_lo: u32, account_hi: u32) NpIdView {
    var view = NpIdView{
        .comm_id = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .account_id = (@as(u64, account_hi) << 32) | account_lo,
    };
    const n = @min(comm_id_raw.len, 9);
    @memcpy(view.comm_id[0..n], comm_id_raw[0..n]);
    return view;
}

/// Content-restriction query result (NP manager): offline default is
/// unrestricted; chat/UGC flags come from the (stubbed) account record.
pub const ContentRestriction = struct {
    chat_allowed: bool = true,
    ugc_allowed: bool = true,
};

/// Save progress dialog: PS4 keeps it open until the guest explicitly closes,
/// unlike the auto-dismissing PS5 dialog. Tiny state machine.
pub const SaveDialog = enum {
    closed,
    open_progress,
    open_complete,

    pub fn onProgress(self: SaveDialog) SaveDialog {
        return switch (self) {
            .closed => .open_progress,
            .open_progress => .open_progress,
            .open_complete => .open_complete,
        };
    }

    pub fn onGuestClose(self: SaveDialog) SaveDialog {
        _ = self;
        return .closed;
    }
};
