const std = @import("std");
const p2z = @import("p2z");

test "vendored core parses a PS4 header" {
    var raw: [p2z.pkg.header_size]u8 = @splat(0);
    @memcpy(raw[0..4], &p2z.pkg.magic);
    std.mem.writeInt(u64, raw[0x430..0x438], 447479808, .big);
    const parsed = p2z.pkg.parseHeader(&raw, 447479808);
    try std.testing.expectEqual(447479808, parsed.ok.package_size);
}
