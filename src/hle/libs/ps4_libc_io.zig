// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! PS4-only libc I/O boundary shim.
//!
//! PS4 titles ship their own libc PRX, whose `fopen` backend never reaches the
//! emulated kernel file APIs: the title's own PRX code opens a file through a
//! guest-internal path that returns a null `FILE*` under emulation, and the
//! MonoGame stream wrappers dereference that null slot. Registering these six
//! exports under the exact PS4 libc NIDs lets the linker route the title's
//! `fopen`/`fread`/... imports to the shared HLE filesystem instead, while the
//! native PS5 path (whose libc resolves its own exports) is left untouched.
//!
//! The `FILE` handle is a small host-side record whose address is returned as
//! an opaque pointer; the guest only ever passes it back to these functions.
//! Its first 16 bytes mirror the guest libc layout (flags at +0, fd at +4,
//! buffer at +8) so guest-internal `fileno`-style field reads stay plausible.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const filesystem = @import("../filesystem.zig");
const kernel_memory = @import("kernel_memory.zig");
const hits = @import("ps4_mode").hits;

const magic: u64 = 0x5049_4f5f_4649_4c45; // "PIO_FILE"

/// The linker only prefers these HLE exports over the title's bundled libc PRX
/// while PS4 compat is active, so a native PS5 title keeps resolving its own
/// libc. The gate lives in ps4_mode (already imported by hle) to avoid a cycle.
pub fn preferred(id: []const u8) bool {
    if (!@import("ps4_mode").game_hook.libc_io_active) return false;
    return std.mem.eql(u8, id, "xeYO4u7uyJ0") or // fopen
        std.mem.eql(u8, id, "uodLYyUip20") or // fclose
        std.mem.eql(u8, id, "lbB+UlZqVG0") or // fread
        std.mem.eql(u8, id, "MpxhMh8QFro") or // fwrite
        std.mem.eql(u8, id, "rQFVBXp-Cxg") or // fseek
        std.mem.eql(u8, id, "Qazy8LmXTvw") or // ftell
        std.mem.eql(u8, id, "MUjC4lbHrK4"); // fflush
}

const File = extern struct {
    flags: u8 = 0,
    reserved0: [3]u8 = .{ 0, 0, 0 },
    fd: i32 = -1,
    buffer: u64 = 0,
    position: u64 = 0,
    marker: u64 = magic,
};

const file_capacity: usize = 128;
var files: [file_capacity]File = [_]File{.{}} ** file_capacity;
var file_lock = std.atomic.Mutex.unlocked;

fn valid(file: ?*File) ?*File {
    const f = file orelse return null;
    if (f.marker != magic or f.fd < 0) return null;
    return f;
}

fn guestString(pointer: ?[*:0]const u8) ?[]const u8 {
    const p = pointer orelse return null;
    const bytes: [*]const u8 = @ptrCast(p);
    const end = std.mem.indexOfScalar(u8, bytes[0 .. filesystem.maximum_path + 1], 0) orelse return null;
    return bytes[0..end];
}

fn guestBytes(pointer: ?[*]u8, length: usize) ?[]u8 {
    const p = pointer orelse return null;
    if (length == 0) return p[0..0];
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(p), length)) return null;
    return p[0..length];
}

pub fn openFile(path: ?[*:0]const u8, mode: ?[*:0]const u8) callconv(abi.guest) u64 {
    hits.record("ps4-libc-fopen");
    const name = guestString(path) orelse return 0;
    var flags: i32 = filesystem.O.rdonly;
    if (mode) |m| {
        const s = guestString(m) orelse "";
        if (std.mem.indexOfScalar(u8, s, '+') != null) {
            flags = filesystem.O.rdwr;
        } else if (std.mem.indexOfScalar(u8, s, 'w') != null or
            std.mem.indexOfScalar(u8, s, 'a') != null)
        {
            flags = filesystem.O.wronly;
        }
    }
    const fd = filesystem.open(name, flags) catch {
        if (trace.announces("fopen")) std.debug.print("[ps4-libc] fopen(\"{s}\") failed\n", .{name});
        return 0;
    };
    while (!file_lock.tryLock()) std.atomic.spinLoopHint();
    defer file_lock.unlock();
    for (&files) |*slot| {
        if (slot.marker == magic and slot.fd >= 0) continue;
        slot.* = .{ .fd = fd };
        if (trace.announces("fopen")) std.debug.print("[ps4-libc] fopen(\"{s}\") -> {d}\n", .{ name, fd });
        return @intFromPtr(slot);
    }
    filesystem.close(fd) catch {};
    return 0;
}

pub fn closeFile(file: ?*File) callconv(abi.guest) i32 {
    hits.record("ps4-libc-fclose");
    const f = valid(file) orelse return -1;
    filesystem.close(f.fd) catch {};
    f.* = .{};
    return 0;
}

pub fn readFile(buffer: ?[*]u8, size: usize, count: usize, file: ?*File) callconv(abi.guest) usize {
    hits.record("ps4-libc-fread");
    const f = valid(file) orelse return 0;
    if (size == 0 or count == 0) return 0;
    const total = std.math.mul(usize, size, count) catch return 0;
    const bytes = guestBytes(buffer, total) orelse return 0;
    const got = filesystem.read(f.fd, bytes) catch return 0;
    f.position += got;
    return got / size;
}

pub fn writeFile(buffer: ?[*]const u8, size: usize, count: usize, file: ?*File) callconv(abi.guest) usize {
    hits.record("ps4-libc-fwrite");
    if (size == 0 or count == 0) return 0;
    const total = std.math.mul(usize, size, count) catch return 0;
    const f = valid(file) orelse {
        // The title's libc pre-opens its own diagnostic streams (stdout/stderr)
        // and writes through this boundary before any fopen. Those FILEs are
        // guest-internal; acknowledge the write so the guest's logging loops
        // advance instead of spinning on a zero return.
        hits.record("ps4-libc-fwrite-guest-stream");
        return count;
    };
    const bytes = buffer orelse return 0;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(bytes), total)) return 0;
    const wrote = filesystem.write(f.fd, bytes[0..total]) catch return 0;
    f.position += wrote;
    return wrote / size;
}

const seek_set: i32 = 0;
const seek_cur: i32 = 1;
const seek_end: i32 = 2;

pub fn seekFile(file: ?*File, offset: i64, whence: i32) callconv(abi.guest) i32 {
    hits.record("ps4-libc-fseek");
    const f = valid(file) orelse return -1;
    const result = filesystem.seek(f.fd, offset, whence) catch return -1;
    f.position = @intCast(@max(result, 0));
    return 0;
}

pub fn tellFile(file: ?*File) callconv(abi.guest) i64 {
    hits.record("ps4-libc-ftell");
    const f = valid(file) orelse return -1;
    return @intCast(f.position);
}

pub fn flushFile(file: ?*File) callconv(abi.guest) i32 {
    hits.record("ps4-libc-fflush");
    return if (valid(file) != null) 0 else -1;
}


/// Returns the real I/O implementation for a PS4 libc NID that the generic
/// title stub table also lists; null for every other NID.
pub fn functionFor(nid: []const u8) ?abi.RawEntryPoint {
    if (std.mem.eql(u8, nid, "xeYO4u7uyJ0")) return @ptrCast(&openFile);
    if (std.mem.eql(u8, nid, "uodLYyUip20")) return @ptrCast(&closeFile);
    if (std.mem.eql(u8, nid, "lbB+UlZqVG0")) return @ptrCast(&readFile);
    if (std.mem.eql(u8, nid, "MpxhMh8QFro")) return @ptrCast(&writeFile);
    if (std.mem.eql(u8, nid, "rQFVBXp-Cxg")) return @ptrCast(&seekFile);
    if (std.mem.eql(u8, nid, "Qazy8LmXTvw")) return @ptrCast(&tellFile);
    if (std.mem.eql(u8, nid, "MUjC4lbHrK4")) return @ptrCast(&flushFile);
    return null;
}

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.add(gpa, .{ .name = "libc", .version = 1 }, .{ .name = "libc" }, .{
        .name = "fopen", .function = trace.wrap("fopen", &openFile), .id_override = "xeYO4u7uyJ0",
    });
    try db.add(gpa, .{ .name = "libc", .version = 1 }, .{ .name = "libc" }, .{
        .name = "fclose", .function = trace.wrap("fclose", &closeFile), .id_override = "uodLYyUip20",
    });
    try db.add(gpa, .{ .name = "libc", .version = 1 }, .{ .name = "libc" }, .{
        .name = "fread", .function = trace.wrap("fread", &readFile), .id_override = "lbB+UlZqVG0",
    });
    try db.add(gpa, .{ .name = "libc", .version = 1 }, .{ .name = "libc" }, .{
        .name = "fwrite", .function = trace.wrap("fwrite", &writeFile), .id_override = "MpxhMh8QFro",
    });
    try db.add(gpa, .{ .name = "libc", .version = 1 }, .{ .name = "libc" }, .{
        .name = "fseek", .function = trace.wrap("fseek", &seekFile), .id_override = "rQFVBXp-Cxg",
    });
    try db.add(gpa, .{ .name = "libc", .version = 1 }, .{ .name = "libc" }, .{
        .name = "ftell", .function = trace.wrap("ftell", &tellFile), .id_override = "Qazy8LmXTvw",
    });
    try db.add(gpa, .{ .name = "libc", .version = 1 }, .{ .name = "libc" }, .{
        .name = "fflush", .function = trace.wrap("fflush", &flushFile), .id_override = "MUjC4lbHrK4",
    });
}

test "PS4 libc I/O exports resolve under their exact NIDs" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    const ids = [_][]const u8{
        "xeYO4u7uyJ0", "uodLYyUip20", "lbB+UlZqVG0", "MpxhMh8QFro",
        "rQFVBXp-Cxg", "Qazy8LmXTvw", "MUjC4lbHrK4",
    };
    for (ids) |id| try std.testing.expect(db.findById(id, .function) != null);
}
