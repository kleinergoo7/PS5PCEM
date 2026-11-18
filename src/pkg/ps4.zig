const std = @import("std");
const p2z = @import("p2z");

/// A PS4 PKG declares its own total size at 0x430; a PS5 raw CNT has no such
/// field, so matching it against the file size separates the two formats.
pub fn isPs4Package(header: []const u8, file_size: u64) bool {
    if (header.len < 0x438) return false;
    if (!std.mem.eql(u8, header[0..4], &p2z.pkg.magic)) return false;
    const package_size = std.mem.readInt(u64, header[0x430..0x438], .big);
    if (package_size != file_size) return false;
    const pfs_offset = std.mem.readInt(u64, header[0x410..0x418], .big);
    return pfs_offset > 0 and pfs_offset < file_size;
}

pub const Stats = struct { files: usize, dirs: usize, bytes: u64 };

fn extractReason(err: anyerror) []const u8 {
    return switch (err) {
        error.OutputExists, error.BackupExists, error.Cancelled, error.CreateFailed,
        error.WriteFailed, error.VerifyFailed, error.RenameFailed, error.ReadFailed,
        error.OutOfMemory,
        => p2z.extractor.reasonName(@errorCast(err)),
        else => @errorName(err),
    };
}

fn probeReason(err: anyerror) []const u8 {
    return p2z.probe.reasonName(@errorCast(err));
}

fn hasTitleId(info: p2z.probe.Info) bool {
    return info.title_id != null;
}

fn preflightIdentity(ident: p2z.plan.Identity, buf: []u8) ?[]const u8 {
    const failure = p2z.plan.preflight(ident, null) orelse return null;
    // bufPrint degrades to a short generic string if the path is unusually long.
    return p2z.plan.describe(failure, buf);
}

pub fn extract(io: std.Io, arena: std.mem.Allocator, input: []const u8, dest: []const u8) !Stats {
    // The probe is the only cheap check that param.sfo is actually present.
    const info = p2z.probe.run(io, arena, input) catch |err| {
        std.debug.print("cannot read PS4 package: {s}\n", .{probeReason(err)});
        return error.InvalidPs4Package;
    };
    if (!hasTitleId(info)) {
        std.debug.print("cannot read PS4 package: no sce_sys/param.sfo title id\n", .{});
        return error.InvalidPs4Package;
    }

    const opened = p2z.source.Source.open(io, arena, &.{input}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    switch (opened) {
        .fail => |fail| {
            var buf: [512]u8 = undefined;
            std.debug.print("cannot read PS4 package: {s}\n", .{p2z.source.describe(fail, &buf)});
            return error.InvalidPs4Package;
        },
        .ok => |source| {
            defer source.close();
            var pbuf: [512]u8 = undefined;
            if (preflightIdentity(p2z.plan.Identity.fromSource(&source), &pbuf)) |reason| {
                std.debug.print("unsupported PS4 package: {s}\n", .{reason});
                return error.UnsupportedPs4Package;
            }
            var sources = [_]p2z.source.Source{source};
            const plan = p2z.plan.build(arena, &sources) catch |err| {
                std.debug.print("cannot plan PS4 extraction: {s}\n", .{@errorName(err)});
                return err;
            };
            var cancel = std.atomic.Value(bool).init(false);
            const stats = p2z.extractor.run(arena, io, &sources, &plan, .{ .output = dest, .cancel = &cancel }) catch |err| {
                std.debug.print("cannot extract PS4 package: {s}\n", .{extractReason(err)});
                return err;
            };
            return .{ .files = stats.files, .dirs = stats.dirs, .bytes = stats.bytes };
        },
    }
}

fn ps4Header() [0x438]u8 {
    var raw: [0x438]u8 = @splat(0);
    raw[0] = 0x7f;
    raw[1] = 'C';
    raw[2] = 'N';
    raw[3] = 'T';
    std.mem.writeInt(u64, raw[0x410..0x418], 0x500000, .big);
    std.mem.writeInt(u64, raw[0x430..0x438], 447479808, .big);
    return raw;
}

test "isPs4Package rejects a short header" {
    const raw = ps4Header();
    try std.testing.expect(!isPs4Package(raw[0..0x100], 447479808));
}

test "isPs4Package rejects a wrong magic" {
    var raw = ps4Header();
    raw[0] = 'X';
    try std.testing.expect(!isPs4Package(&raw, 447479808));
}

test "isPs4Package rejects a mismatched package size" {
    const raw = ps4Header();
    try std.testing.expect(!isPs4Package(&raw, 447479809));
}

test "isPs4Package rejects a missing PFS image" {
    var raw = ps4Header();
    std.mem.writeInt(u64, raw[0x410..0x418], 0, .big);
    try std.testing.expect(!isPs4Package(&raw, 447479808));
}

test "probe info without a title id is rejected" {
    const empty: p2z.probe.Info = .{};
    try std.testing.expect(!hasTitleId(empty));
    const titled: p2z.probe.Info = .{ .title_id = "CUSA34845" };
    try std.testing.expect(hasTitleId(titled));
}

test "isPs4Package recognises a PS4 package header" {
    const raw = ps4Header();
    try std.testing.expect(isPs4Package(&raw, 447479808));
}

test "extractReason names an existing output directory" {
    try std.testing.expectEqualStrings("output folder already exists", extractReason(error.OutputExists));
}

test "probeReason names a missing param.sfo" {
    try std.testing.expectEqualStrings("pkg has no sce_sys/param.sfo entry", probeReason(error.MissingParamSfo));
}

test "preflightIdentity refuses a delta patch" {
    const ident = p2z.plan.Identity{
        .content_id = "UP4127-CUSA34845_00-ONESHOTWMEUS0000",
        .content_flags = p2z.pkg.content_flag_delta_patch,
        .content_type = p2z.plan.game_content_type,
        .pfs_image_count = 1,
        .path = "delta.pkg",
    };
    var buf: [512]u8 = undefined;
    const reason = preflightIdentity(ident, &buf) orelse return error.TestExpectedRefusal;
    try std.testing.expect(std.mem.indexOf(u8, reason, "delta") != null);
}

test "preflightIdentity accepts a normal game" {
    const ident = p2z.plan.Identity{
        .content_id = "UP4127-CUSA34845_00-ONESHOTWMEUS0000",
        .content_flags = 0,
        .content_type = p2z.plan.game_content_type,
        .pfs_image_count = 1,
        .path = "game.pkg",
    };
    var buf: [512]u8 = undefined;
    try std.testing.expect(preflightIdentity(ident, &buf) == null);
}
