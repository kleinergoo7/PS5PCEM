// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Output names: `Terraria (CUSA00740) v01.00.zar`, with role suffixes for merges and for
//! separate conversion. Pure functions so the rules are testable without touching files.

const std = @import("std");

pub const Role = enum {
    single,
    merged,
    base,
    update,
};

pub const Info = struct {
    title: ?[]const u8 = null,
    title_id: ?[]const u8 = null,
    version: ?[]const u8 = null,
    role: Role = .single,
};

/// Builds the file or folder name without an extension. Falls back to `fallback` (a source
/// file stem) when neither title nor title id is known.
pub fn derive(
    arena: std.mem.Allocator,
    info: Info,
    fallback: []const u8,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;

    const title = if (info.title) |t| sanitize(arena, t) catch return error.OutOfMemory else null;
    const version = if (info.version) |v| sanitize(arena, v) catch return error.OutOfMemory else null;

    if (title) |t| {
        if (t.len > 0) {
            try out.appendSlice(arena, t);
            if (info.title_id != null) try out.appendSlice(arena, " ");
        }
    } else if (info.title_id == null) {
        try out.appendSlice(arena, fallback);
    }

    if (info.title_id) |id| {
        const clean = sanitize(arena, id) catch return error.OutOfMemory;
        if (title != null) {
            try out.print(arena, "({s})", .{clean});
        } else {
            try out.appendSlice(arena, clean);
        }
    }
    if (version) |v| {
        if (v.len > 0) try out.print(arena, " v{s}", .{v});
    }
    switch (info.role) {
        .single => {},
        .merged => try out.appendSlice(arena, " - merged"),
        .base => try out.appendSlice(arena, " - base"),
        .update => try out.appendSlice(arena, " - update"),
    }
    return out.toOwnedSlice(arena);
}

/// Replaces characters Windows rejects in file names and trims trailing dots and spaces.
fn sanitize(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    var len: usize = 0;
    for (text) |c| {
        const bad = c < 0x20 or c == 0x7f or c == '/' or c == '\\' or c == ':' or c == '*' or
            c == '?' or c == '"' or c == '<' or c == '>' or c == '|';
        out[len] = if (bad) '_' else c;
        len += 1;
    }
    while (len > 0 and (out[len - 1] == '.' or out[len - 1] == ' ')) len -= 1;
    if (len > 200) len = 200;
    return out[0..len];
}

test "derive: title, id and version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Terraria (CUSA00740) v01.00", try derive(arena, .{
        .title = "Terraria",
        .title_id = "CUSA00740",
        .version = "01.00",
    }, "fallback"));

    try std.testing.expectEqualStrings("Terraria (CUSA00740) v01.35 - merged", try derive(arena, .{
        .title = "Terraria",
        .title_id = "CUSA00740",
        .version = "01.35",
        .role = .merged,
    }, "fallback"));

    try std.testing.expectEqualStrings("Terraria (CUSA00740) v01.00 - base", try derive(arena, .{
        .title = "Terraria",
        .title_id = "CUSA00740",
        .version = "01.00",
        .role = .base,
    }, "fallback"));
}

test "derive: falls back when fields are missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("CUSA00740", try derive(arena, .{ .title_id = "CUSA00740" }, "fallback"));
    try std.testing.expectEqualStrings("fallback", try derive(arena, .{}, "fallback"));
    try std.testing.expectEqualStrings("Terraria (CUSA00740)", try derive(arena, .{
        .title = "Terraria",
        .title_id = "CUSA00740",
    }, "fallback"));
}

test "derive: sanitises illegal characters and trailing dots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("A_B_C (CUSA1) v1_0", try derive(arena, .{
        .title = "A/B:C",
        .title_id = "CUSA1",
        .version = "1*0",
    }, "fallback"));

    // A title ending in a dot must not produce a name ending in a dot.
    try std.testing.expectEqualStrings("Game (CUSA1)", try derive(arena, .{
        .title = "Game.",
        .title_id = "CUSA1",
    }, "fallback"));
}
