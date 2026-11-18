// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Preflight checks and the merge plan. This decides what the output archive contains
//! before a single byte is written. All matching is case-insensitive.

const std = @import("std");
const pkg = @import("pkg.zig");
const pfs = @import("pfs.zig");
const source = @import("source.zig");

pub const game_content_type: u32 = 0x1a;

pub const Failure = union(enum) {
    title_mismatch: struct { base: []const u8, update: []const u8 },
    entitlement_mismatch: struct { base: []const u8, update: []const u8 },
    base_is_patch: struct { path: []const u8 },
    update_not_patch: struct { path: []const u8 },
    delta_patch: struct { path: []const u8 },
    content_type_unsupported: struct { path: []const u8, value: u32 },
    image_count_unsupported: struct { path: []const u8, count: u32 },
    duplicate_path: struct { path: []const u8 },
};

pub fn describe(failure: Failure, buf: []u8) []const u8 {
    return switch (failure) {
        .title_mismatch => |m| std.fmt.bufPrint(buf, "title id mismatch: base {s}, update {s}", .{ m.base, m.update }) catch "title id mismatch",
        .entitlement_mismatch => |m| std.fmt.bufPrint(buf, "entitlement mismatch: base {s}, update {s}", .{ m.base, m.update }) catch "entitlement mismatch",
        .base_is_patch => |f| std.fmt.bufPrint(buf, "{s}: input is a patch, expected the base game", .{f.path}) catch "base is a patch",
        .update_not_patch => |f| std.fmt.bufPrint(buf, "{s}: input is not a patch, expected the update", .{f.path}) catch "update is not a patch",
        .delta_patch => |f| std.fmt.bufPrint(buf, "{s}: delta update, not supported yet", .{f.path}) catch "delta update not supported",
        .content_type_unsupported => |f| std.fmt.bufPrint(buf, "{s}: content type 0x{X} is not a game (DLC and non-game layouts are not supported)", .{ f.path, f.value }) catch "unsupported content type",
        .image_count_unsupported => |f| std.fmt.bufPrint(buf, "{s}: pfs_image_count is {d}, only 1 is supported", .{ f.path, f.count }) catch "unsupported image count",
        .duplicate_path => |f| std.fmt.bufPrint(buf, "two entries map to the same path: {s}", .{f.path}) catch "duplicate archive path",
    };
}

pub const Kind = enum { pkg_entry, pfs_file, pfs_dir };

pub const Item = struct {
    path: []const u8,
    source_index: u8,
    kind: Kind,
    entry: ?pkg.Entry = null,
    pfs_entry: ?pfs.Entry = null,
};

pub const Plan = struct {
    items: []Item,
    total_bytes: u64,
    file_count: usize,
    dir_count: usize,
    overrides: usize,
};

/// The header facts preflight needs. Kept separate from Source so the checks are testable
/// without opening files.
pub const Identity = struct {
    content_id: []const u8,
    content_flags: u32,
    content_type: u32,
    pfs_image_count: u32,
    path: []const u8,

    pub fn fromSource(src: *const source.Source) Identity {
        return .{
            .content_id = src.contentId(),
            .content_flags = src.header.content_flags,
            .content_type = src.header.content_type,
            .pfs_image_count = src.header.pfs_image_count,
            .path = src.paths[0],
        };
    }

    pub fn titleId(self: Identity) ?[]const u8 {
        if (self.content_id.len < 16 or self.content_id[6] != '-') return null;
        return self.content_id[7..16];
    }

    pub fn entitlement(self: Identity) ?[]const u8 {
        if (self.content_id.len < 7 or self.content_id[6] != '-') return null;
        return self.content_id[0..6];
    }
};

/// True when the two inputs are listed update-first. Roles are semantic, not positional, so
/// callers may swap and continue.
pub fn shouldSwapRoles(base: Identity, update: Identity) bool {
    return pkg.isPatch(base.content_flags) and !pkg.isPatch(update.content_flags);
}

/// Refuses inputs that cannot be merged or converted. `update` is null for a single pkg.
pub fn preflight(base: Identity, update: ?Identity) ?Failure {
    if (pkg.isDeltaPatch(base.content_flags)) return .{ .delta_patch = .{ .path = base.path } };
    if (base.content_type != game_content_type) {
        return .{ .content_type_unsupported = .{ .path = base.path, .value = base.content_type } };
    }
    if (base.pfs_image_count > 1) {
        return .{ .image_count_unsupported = .{ .path = base.path, .count = base.pfs_image_count } };
    }

    // A patch converted on its own is job 2 of the tool, so only a merge rejects it here.
    const upd = update orelse return null;
    if (pkg.isPatch(base.content_flags)) return .{ .base_is_patch = .{ .path = base.path } };
    if (pkg.isDeltaPatch(upd.content_flags)) return .{ .delta_patch = .{ .path = upd.path } };
    if (upd.content_type != game_content_type) {
        return .{ .content_type_unsupported = .{ .path = upd.path, .value = upd.content_type } };
    }
    if (upd.pfs_image_count > 1) {
        return .{ .image_count_unsupported = .{ .path = upd.path, .count = upd.pfs_image_count } };
    }
    if (!pkg.isPatch(upd.content_flags)) {
        // Two base games, or the inputs are swapped. Both are worth refusing loudly.
        if (pkg.isPatch(base.content_flags)) return .{ .base_is_patch = .{ .path = base.path } };
        return .{ .update_not_patch = .{ .path = upd.path } };
    }

    const base_title = base.titleId() orelse return .{ .title_mismatch = .{ .base = base.content_id, .update = upd.content_id } };
    const upd_title = upd.titleId() orelse return .{ .title_mismatch = .{ .base = base.content_id, .update = upd.content_id } };
    if (!std.mem.eql(u8, base_title, upd_title)) {
        return .{ .title_mismatch = .{ .base = base_title, .update = upd_title } };
    }
    const base_ent = base.entitlement() orelse return .{ .entitlement_mismatch = .{ .base = base.content_id, .update = upd.content_id } };
    const upd_ent = upd.entitlement() orelse return .{ .entitlement_mismatch = .{ .base = base.content_id, .update = upd.content_id } };
    if (!std.mem.eql(u8, base_ent, upd_ent)) {
        return .{ .entitlement_mismatch = .{ .base = base_ent, .update = upd_ent } };
    }
    return null;
}

/// Builds the merged archive plan. `sources[0]` is the base, `sources[1]` the update.
pub fn build(arena: std.mem.Allocator, sources: []const source.Source) !Plan {
    if (sources.len == 0 or sources.len > 2) return error.UnsupportedSourceCount;

    var items: std.ArrayListUnmanaged(Item) = .empty;
    var index = std.StringHashMapUnmanaged(usize).empty;
    var overrides: usize = 0;

    for (sources, 0..) |*src, source_index| {
        const sce = try src.sceFiles();
        for (sce) |file| {
            if (try addItem(arena, &items, &index, .{
                .path = file.path,
                .source_index = @intCast(source_index),
                .kind = .pkg_entry,
                .entry = file.entry,
            })) overrides += 1;
        }
        for (src.walk.entries) |entry| {
            if (try addItem(arena, &items, &index, .{
                .path = entry.path,
                .source_index = @intCast(source_index),
                .kind = if (entry.kind == .file) .pfs_file else .pfs_dir,
                .pfs_entry = entry,
            })) overrides += 1;
        }
    }

    var total: u64 = 0;
    var files: usize = 0;
    var dirs: usize = 0;
    for (items.items) |item| {
        switch (item.kind) {
            .pfs_dir => dirs += 1,
            .pkg_entry => {
                files += 1;
                total += item.entry.?.size;
            },
            .pfs_file => {
                files += 1;
                total += item.pfs_entry.?.size;
            },
        }
    }

    return .{
        .items = try items.toOwnedSlice(arena),
        .total_bytes = total,
        .file_count = files,
        .dir_count = dirs,
        .overrides = overrides,
    };
}

/// Adds one item plus any missing parent directories. A later item with the same
/// case-insensitive path replaces the earlier one, which is how the update wins.
fn addItem(
    arena: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(Item),
    index: *std.StringHashMapUnmanaged(usize),
    item: Item,
) !bool {
    var slash_index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, item.path, slash_index, '/')) |slash| {
        slash_index = slash + 1;
        const parent = item.path[0..slash];
        if (parent.len == 0) continue;
        const key = try lower(arena, parent);
        if (!index.contains(key)) {
            const at = items.items.len;
            try items.append(arena, .{
                .path = parent,
                .source_index = item.source_index,
                .kind = .pfs_dir,
            });
            try index.put(arena, key, at);
        }
    }

    const key = try lower(arena, item.path);
    if (index.get(key)) |existing| {
        items.items[existing] = item;
        return true;
    }
    try index.put(arena, key, items.items.len);
    try items.append(arena, item);
    return false;
}

fn lower(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "shouldSwapRoles: detects an update listed first" {
    const base = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", 0x0A000000);
    const patch = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", 0x62300000);
    try std.testing.expect(!shouldSwapRoles(base, patch));
    try std.testing.expect(shouldSwapRoles(patch, base));
    try std.testing.expect(!shouldSwapRoles(base, base));
    try std.testing.expect(!shouldSwapRoles(patch, patch));
}

test "preflight: accepts the real base and update" {
    const base = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", 0x0A000000);
    const upd = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", 0x62300000);
    try std.testing.expect(preflight(base, upd) == null);
    try std.testing.expect(preflight(base, null) == null);
    // Job 2: an update converted on its own is legal.
    try std.testing.expect(preflight(upd, null) == null);
}

test "preflight: refuses a title mismatch and a swapped pair" {
    const base = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", 0x0A000000);
    const other = makeIdentity("UP4040-CUSA99999_00-TERRARIA00000001", 0x62300000);
    const mismatch = preflight(base, other) orelse return error.ExpectedFailure;
    try std.testing.expect(mismatch == .title_mismatch);

    const not_patch = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", 0x0A000000);
    const swapped = preflight(base, not_patch) orelse return error.ExpectedFailure;
    try std.testing.expect(swapped == .update_not_patch);
}

test "preflight: refuses delta patches, DLC content types and multi-image pkgs" {
    var base = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", pkg.content_flag_delta_patch);
    try std.testing.expect(preflight(base, null).? == .delta_patch);

    base = makeIdentity("UP4040-CUSA00740_00-TERRARIA00000001", 0x0A000000);
    base.content_type = 0x1b;
    try std.testing.expect(preflight(base, null).? == .content_type_unsupported);

    base.content_type = game_content_type;
    base.pfs_image_count = 2;
    try std.testing.expect(preflight(base, null).? == .image_count_unsupported);
}

test "merge: update replaces a base entry with different casing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var items: std.ArrayListUnmanaged(Item) = .empty;
    var index = std.StringHashMapUnmanaged(usize).empty;
    _ = try addItem(arena, &items, &index, .{ .path = "Media/config.json", .source_index = 0, .kind = .pfs_file });
    try std.testing.expect(try addItem(arena, &items, &index, .{ .path = "media/CONFIG.json", .source_index = 1, .kind = .pfs_file }));

    try std.testing.expectEqual(@as(usize, 2), items.items.len); // dir plus the file
    try std.testing.expectEqual(@as(u8, 1), items.items[1].source_index);
    try std.testing.expectEqualStrings("media/CONFIG.json", items.items[1].path);
}

test "merge: adds missing parent directories once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var items: std.ArrayListUnmanaged(Item) = .empty;
    var index = std.StringHashMapUnmanaged(usize).empty;
    _ = try addItem(arena, &items, &index, .{ .path = "a/b/c.txt", .source_index = 0, .kind = .pfs_file });
    _ = try addItem(arena, &items, &index, .{ .path = "a/b/d.txt", .source_index = 0, .kind = .pfs_file });

    try std.testing.expectEqual(@as(usize, 4), items.items.len);
    try std.testing.expectEqualStrings("a", items.items[0].path);
    try std.testing.expectEqualStrings("a/b", items.items[1].path);
}

fn makeIdentity(content_id: []const u8, flags: u32) Identity {
    return .{
        .content_id = content_id,
        .content_flags = flags,
        .content_type = game_content_type,
        .pfs_image_count = 1,
        .path = "fixture.pkg",
    };
}
