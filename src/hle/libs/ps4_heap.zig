// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Real guest heap backing the PS4 allocator imports.
//!
//! DRIVECLUB's libc/mspace allocators (malloc, calloc, memalign, free,
//! sceLibcMspaceMalloc/Free) were zero-stubs; the first bootstrap memset on a
//! null-derived pointer faulted. This heap reserves flexible-memory arenas
//! through the existing kernel_memory entry points and sub-allocates with a
//! sorted first-fit free list, so boot proceeds past allocator users. The
//! mspace handle is accepted and ignored: one process-wide heap backs all
//! callers, which matches single-mspace title behavior.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_memory = @import("kernel_memory.zig");

const header_size: u64 = 16;
const min_block: u64 = 32;
const chunk_len: u64 = 64 * 1024 * 1024;
const max_chunks: usize = 8;
const heap_magic: u64 = 0x5048_4541_5053_3433;

const Header = struct {
    size: u64, // total block bytes including header
    magic: u64,
};

var heap_lock = std.atomic.Mutex.unlocked;
var chunks: [max_chunks]u64 = [_]u64{0} ** max_chunks;
var chunk_count: usize = 0;
var free_head: u64 = 0; // guest address of first free block, 0 = empty

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) & ~(a - 1);
}

fn writeHeader(at: u64, size: u64) void {
    const h: *Header = @ptrFromInt(at);
    h.size = size;
    h.magic = heap_magic;
}

fn readHeader(at: u64) Header {
    return @as(*const Header, @ptrFromInt(at)).*;
}

fn setNext(block: u64, next: u64) void {
    @as(*u64, @ptrFromInt(block + header_size)).* = next;
}

fn getNext(block: u64) u64 {
    return @as(*const u64, @ptrFromInt(block + header_size)).*;
}

/// Map one more arena chunk. Caller holds the lock.
fn growLocked() bool {
    if (chunk_count >= max_chunks) return false;
    var addr: u64 = 0;
    var cname = [_:0]u8{ 'p', 's', '4', 'h', 'e', 'a', 'p', 0 };
    // Flags 0: plain auto-placed anonymous mapping (the SCE flag set has
    // no POSIX MAP_ANONYMOUS bit; 0x1000 is rejected with EINVAL).
    const rc = kernel_memory.sceKernelMapNamedFlexibleMemory(&addr, chunk_len, 3, 0, &cname);
    if (rc != errno.ok or addr == 0) {
        std.debug.print("[ps4heap] arena map failed rc={d} addr=0x{x}\n", .{ rc, addr });
        return false;
    }
    chunks[chunk_count] = addr;
    chunk_count += 1;
    // Whole chunk starts as one free block, inserted sorted.
    writeHeader(addr, chunk_len);
    insertFreeLocked(addr);
    return true;
}

/// Insert a free block sorted by address, merging neighbours. Lock held.
fn insertFreeLocked(block: u64) void {
    const size = readHeader(block).size;
    var prev: u64 = 0;
    var cur = free_head;
    while (cur != 0 and cur < block) {
        prev = cur;
        cur = getNext(cur);
    }
    // Merge with next.
    if (cur != 0 and block + size == cur) {
        writeHeader(block, size + readHeader(cur).size);
        cur = getNext(cur);
    }
    // Merge with prev.
    if (prev != 0 and prev + readHeader(prev).size == block) {
        writeHeader(prev, readHeader(prev).size + readHeader(block).size);
    } else {
        setNext(block, cur);
        if (prev == 0) free_head = block else setNext(prev, block);
    }
}

/// Allocate `size` user bytes with `alignment`. Lock held. Returns user ptr.
fn allocLocked(size: u64, alignment: u64) u64 {
    const need = @max(alignUp(size + header_size, 16), min_block);
    while (true) {
        var prev: u64 = 0;
        var cur = free_head;
        while (cur != 0) {
            const bsize = readHeader(cur).size;
            const next = getNext(cur);
            // Aligned user address inside this block.
            const user = alignUp(cur + header_size, alignment);
            const pad = user - (cur + header_size);
            if (bsize >= pad + need) {
                // Unlink cur; reinsert leftovers through the normal path.
                if (prev == 0) free_head = next else setNext(prev, next);
                var acur = cur;
                var asize = bsize;
                if (pad >= min_block) {
                    writeHeader(acur, pad);
                    insertFreeLocked(acur);
                    acur = user - header_size;
                    asize = bsize - pad;
                }
                // If the header cannot sit 16 below the user pointer
                // (tiny absorbed pad), the pad bytes leak inside this
                // allocation: safe, just untracked.
                const hpos = if (acur + header_size == user) acur else user - header_size;
                const use = need;
                const leftover = asize - (hpos - acur) - use;
                if (leftover >= min_block) {
                    writeHeader(hpos, (hpos - acur) + use);
                    const tail = hpos + (hpos - acur) + use;
                    writeHeader(tail, leftover);
                    insertFreeLocked(tail);
                } else {
                    writeHeader(hpos, asize - (hpos - acur));
                }
                return user;
            }
            prev = cur;
            cur = next;
        }
        if (!growLocked()) return 0;
    }
}

fn freeLocked(ptr: u64) void {
    if (ptr == 0) return;
    // The header sits 16 bytes below for naturally aligned blocks; for
    // memalign blocks the header is 16 bytes below the user pointer too
    // (allocLocked places it there). Validate before trusting.
    if (ptr < header_size) return;
    const h = readHeader(ptr - header_size);
    if (h.magic != heap_magic) return;
    if (h.size < min_block or h.size > chunk_len) return;
    insertFreeLocked(ptr - header_size);
}

fn heapLock() void {
    while (!heap_lock.tryLock()) std.atomic.spinLoopHint();
}

fn heapUnlock() void {
    heap_lock.unlock();
}

fn mallocImpl(size: u64) u64 {
    heapLock();
    defer heapUnlock();
    const ptr = allocLocked(if (size == 0) 1 else size, 16);
    std.debug.print("[ps4heap] malloc(0x{x}) = 0x{x}\n", .{ size, ptr });
    return ptr;
}

fn callocImpl(n: u64, size: u64) u64 {
    const total = std.math.mul(u64, n, size) catch return 0;
    heapLock();
    defer heapUnlock();
    const ptr = allocLocked(if (total == 0) 1 else total, 16);
    if (ptr != 0) {
        const bytes: [*]u8 = @ptrFromInt(ptr);
        @memset(bytes[0..total], 0);
    }
    return ptr;
}

fn memalignImpl(alignment: u64, size: u64) u64 {
    const a = if (alignment < 16 or !std.math.isPowerOfTwo(alignment)) 16 else alignment;
    heapLock();
    defer heapUnlock();
    return allocLocked(if (size == 0) 1 else size, a);
}

fn freeImpl(ptr: u64) void {
    heapLock();
    defer heapUnlock();
    freeLocked(ptr);
}

fn ps4Malloc(size: u64) callconv(abi.guest) u64 {
    return mallocImpl(size);
}

fn ps4Calloc(n: u64, size: u64) callconv(abi.guest) u64 {
    return callocImpl(n, size);
}

fn ps4Memalign(alignment: u64, size: u64) callconv(abi.guest) u64 {
    return memalignImpl(alignment, size);
}

fn ps4Free(ptr: u64) callconv(abi.guest) void {
    freeImpl(ptr);
}

fn ps4MspaceMalloc(_: u64, size: u64) callconv(abi.guest) u64 {
    return mallocImpl(size);
}

fn ps4MspaceFree(_: u64, ptr: u64) callconv(abi.guest) void {
    freeImpl(ptr);
}

fn reallocImpl(old_ptr: u64, size: u64) u64 {
    if (old_ptr == 0) return mallocImpl(size);
    if (size == 0) {
        freeImpl(old_ptr);
        return mallocImpl(1);
    }
    heapLock();
    defer heapUnlock();
    if (old_ptr < header_size) return 0;
    const h = readHeader(old_ptr - header_size);
    if (h.magic != heap_magic or h.size < min_block or h.size > chunk_len) return 0;
    const old_user = h.size - header_size;
    if (size <= old_user) return old_ptr;
    const new_ptr = allocLocked(size, 16);
    if (new_ptr == 0) return 0;
    const copy_len = @min(old_user, size);
    const dst: [*]u8 = @ptrFromInt(new_ptr);
    const src: [*]const u8 = @ptrFromInt(old_ptr);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    freeLocked(old_ptr);
    return new_ptr;
}

fn ps4Realloc(old_ptr: u64, size: u64) callconv(abi.guest) u64 {
    return reallocImpl(old_ptr, size);
}

// C++ operators route to the same heap. Throwing new keeps standard
// semantics for free: our allocator only fails past the arena budget, in
// which case returning null lets the caller's own check (or libc++abi's
// new handler path) raise bad_alloc exactly as on hardware.
fn ps4New(size: u64) callconv(abi.guest) u64 {
    return mallocImpl(size);
}

fn ps4NewArray(size: u64) callconv(abi.guest) u64 {
    return mallocImpl(size);
}

fn ps4Delete(ptr: u64) callconv(abi.guest) void {
    freeImpl(ptr);
}

fn ps4DeleteArray(ptr: u64) callconv(abi.guest) void {
    freeImpl(ptr);
}

// BRING-UP MITIGATION (DRIVECLUB CUSA00003): guest init calls
// strcpy(online_heap_dst, NULL) when an upstream service/stub leaves a name
// pointer NULL (observed: libc.prx kiZSXIWd9vg+0x47, dst=0x2016000061,
// src=0). Real libc would fault; treat NULL src as "" so boot can progress
// while the NULL provider is fixed. Logged so it stays visible.
fn ps4Strcpy(dst: u64, src: u64) callconv(abi.guest) u64 {
    if (dst == 0) return 0;
    const out: [*]u8 = @ptrFromInt(dst);
    if (src == 0) {
        std.log.warn("[ps4heap] strcpy(dst=0x{x}, NULL): substituting empty string (bring-up mitigation)", .{dst});
        out[0] = 0;
        return dst;
    }
    const in: [*]const u8 = @ptrFromInt(src);
    var i: usize = 0;
    while (true) : (i += 1) {
        out[i] = in[i];
        if (in[i] == 0) break;
        if (i > 0x10_0000) { // safety cap; real strings won't hit this
            out[i] = 0;
            std.log.warn("[ps4heap] strcpy capped at 1MiB src=0x{x}", .{src});
            break;
        }
    }
    return dst;
}

// BRING-UP MITIGATION (DRIVECLUB CUSA00003): memset(NULL, c, 0xc0000) observed
// during threaded init (libc.prx 8zTFvBIAIN8+0x48) after online/file_system/
// ram_file_system heap setup — a NULL buffer pointer zeroed unguarded.
// Log args and skip so the NULL provider can be identified and fixed.
fn ps4Memset(dst: u64, val: u64, len: u64) callconv(abi.guest) u64 {
    if (dst == 0) {
        std.log.warn("[ps4heap] memset(NULL, val=0x{x}, len=0x{x}): skipping (bring-up mitigation)", .{ val, len });
        return 0;
    }
    const n: usize = @intCast(len);
    @memset(@as([*]u8, @ptrFromInt(dst))[0..n], @truncate(val));
    return dst;
}

pub const exports = [_]symbols.Export{
    .{ .name = "malloc", .function = trace.wrap("ps4-malloc", &ps4Malloc), .id_override = "gQX+4GDQjpM" },
    .{ .name = "calloc", .function = trace.wrap("ps4-calloc", &ps4Calloc), .id_override = "2X5agFjKxMc" },
    .{ .name = "memalign", .function = trace.wrap("ps4-memalign", &ps4Memalign), .id_override = "Ujf3KzMvRmI" },
    .{ .name = "free", .function = trace.wrap("ps4-free", &ps4Free), .id_override = "tIhsqj0qsFE" },
    .{ .name = "sceLibcMspaceMalloc", .function = trace.wrap("ps4-mspace-malloc", &ps4MspaceMalloc), .id_override = "OJjm-QOIHlI" },
    .{ .name = "sceLibcMspaceFree", .function = trace.wrap("ps4-mspace-free", &ps4MspaceFree), .id_override = "Vla-Z+eXlxo" },
    .{ .name = "realloc", .function = trace.wrap("ps4-realloc", &ps4Realloc), .id_override = "Y7aJ1uydPMo" },
    .{ .name = "operator new", .function = trace.wrap("ps4-new", &ps4New), .id_override = "fJnpuVVBbKk" },
    .{ .name = "operator new[]", .function = trace.wrap("ps4-new-array", &ps4NewArray), .id_override = "hdm0YfMa7TQ" },
    .{ .name = "operator delete", .function = trace.wrap("ps4-delete", &ps4Delete), .id_override = "z+P+xCnWLBk" },
    .{ .name = "operator delete[]", .function = trace.wrap("ps4-delete-array", &ps4DeleteArray), .id_override = "MLWl90SFWNE" },
    .{ .name = "operator new nothrow", .function = trace.wrap("ps4-new-nothrow", &ps4New), .id_override = "ryUxD-60bKM" },
    .{ .name = "operator new[] nothrow", .function = trace.wrap("ps4-new-array-nothrow", &ps4NewArray), .id_override = "Jh5qUcwiSEk" },
    .{ .name = "strcpy", .function = trace.wrap("ps4-strcpy", &ps4Strcpy), .id_override = "kiZSXIWd9vg" },
    .{ .name = "memset", .function = trace.wrap("ps4-memset", &ps4Memset), .id_override = "8zTFvBIAIN8" },
};

pub const library = symbols.Library{ .name = "libc", .version = 1 };
pub const module = symbols.Module{ .name = "libc", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}
