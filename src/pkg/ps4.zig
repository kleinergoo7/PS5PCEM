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

pub fn extract(io: std.Io, arena: std.mem.Allocator, input: []const u8, dest: []const u8) !Stats {
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
            var sources = [_]p2z.source.Source{source};
            const plan = try p2z.plan.build(arena, &sources);
            var cancel = std.atomic.Value(bool).init(false);
            const stats = try p2z.extractor.run(arena, io, &sources, &plan, .{ .output = dest, .cancel = &cancel });
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

test "isPs4Package recognises a PS4 package header" {
    const raw = ps4Header();
    try std.testing.expect(isPs4Package(&raw, 447479808));
}
