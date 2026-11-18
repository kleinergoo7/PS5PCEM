# PS4 PKG extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `pkgextractor` fully unpack PS4 fake-signed PKGs into a runnable game tree.

**Architecture:** Vendor the pinned `pkg2zar` core (Zig, already verified byte-for-byte against a reference extractor) as a 0.16-compatible module, wrap it in a small PS4 detector/extractor, and dispatch to it from `pkgextractor` when the header identifies a PS4 package. Existing PS5 FIH/CNT and ZAR paths stay untouched.

**Tech Stack:** Zig 0.16.0 (`/home/reng/tools/zig-x86_64-linux-0.16.0/zig`), no new runtime dependency.

**Spec:** `docs/superpowers/specs/2026-11-18-ps4-pkg-extraction-design.md`

## Global Constraints

- PS5PCEM stays on **Zig 0.16.0**. Do not add `pkg2zar` as a `build.zig.zon` package dependency (its `build.zig` uses 0.17 APIs and fails on 0.16); vendor `core/src` only.
- Vendor from commit `26abc7504b401e7aaff4caf222d0e85ce999ba4d` of `https://github.com/kleinergoo7/pkg2zar`, GPL-3.0; keep upstream `LICENSE` and `NOTICE`, and record the commit in `NOTICE`.
- ps5pcem build cache stays **under 1 GB**; use the existing cache setup (`ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`, local `.zig-cache`) and recheck at the end.
- No user-supplied keys, no firmware, no external binary at runtime.

## Review Focus

- A PS5 FPKG sent through the new path must still use the old extraction — pin with the `isPs4Package` unit test (wrong `package_size`) and the existing `detectKind` tests.
- A truncated/short CNT header must not be read out of bounds — pin with the `header.len < 0x438` case in the detection test.
- `extract` failures (bad header, corrupt PFS, missing param.sfo) must report a reason instead of silently writing an empty tree — pin with the `.fail` branch in `extract` and a CLI check on a bogus `.pkg`.
- An existing output directory must not be destroyed — `extractor.run` returns `error.OutputExists` unless `overwrite`; keep `overwrite = false`.
- The 4-byte `sce_sys/npbind.dat` tail difference from the reference is expected and must not be "fixed" — pin with the manifest comparison in Task 3.

---

### Task 1: Vendor the pinned core and add a 0.16 build module

**Files:**
- Create: `vendor/pkg2zar/core/src/*.zig` (all 18 files from the pinned commit)
- Create: `vendor/pkg2zar/LICENSE`, `vendor/pkg2zar/NOTICE`
- Create: `tests/p2z_smoke.zig`
- Modify: `build.zig` (module + test wiring near `zarchive_tests`, ~line 935)

**Interfaces:**
- Consumes: nothing.
- Produces: Zig module `p2z` whose root is `vendor/pkg2zar/core/src/root.zig`; exposed declarations used later: `p2z.pkg.parseHeader`, `p2z.source.Source.open`, `p2z.plan.build`, `p2z.extractor.run`, `p2z.source.describe`.

- [ ] **Step 1: Vendor the files**

```bash
mkdir -p vendor/pkg2zar/core/src tests
cp /tmp/opencode/pkg2zar/core/src/*.zig vendor/pkg2zar/core/src/
cp /tmp/opencode/pkg2zar/LICENSE /tmp/opencode/pkg2zar/NOTICE vendor/pkg2zar/
```

Append to `vendor/pkg2zar/NOTICE`: `Vendored from kleinergoo7/pkg2zar commit 26abc7504b401e7aaff4caf222d0e85ce999ba4d; core only, built with Zig 0.16.0.`

- [ ] **Step 2: Write the failing smoke test**

`tests/p2z_smoke.zig`:

```zig
const std = @import("std");
const p2z = @import("p2z");

test "vendored core parses a PS4 header" {
    var raw: [p2z.pkg.header_size]u8 = @splat(0);
    @memcpy(raw[0..4], &p2z.pkg.magic);
    std.mem.writeInt(u64, raw[0x430..0x438], 447479808, .big);
    const parsed = p2z.pkg.parseHeader(&raw, 447479808);
    try std.testing.expectEqual(447479808, parsed.ok.package_size);
}
```

- [ ] **Step 3: Add the module and test wiring in `build.zig`**

Add `const p2z = b.addModule("p2z", .{ .root_source_file = b.path("vendor/pkg2zar/core/src/root.zig"), .target = target, .optimize = optimize });` beside the other modules; add a `p2z_smoke` test module with `.imports = &.{.{ .name = "p2z", .module = p2z }}` and hook its `run` step into `test_step`.

- [ ] **Step 4: Run the smoke test**

Run: `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test -Dtest-filter=vendored`
Expected: PASS (fails before Step 3 because module `p2z` is not found).

- [ ] **Step 5: Commit**

`git add vendor/pkg2zar tests/p2z_smoke.zig build.zig && git commit -m "vendor: pin pkg2zar core for PS4 PKG extraction"`

---

### Task 2: PS4 detector and extraction wrapper

**Files:**
- Create: `src/pkg/ps4.zig`
- Modify: `build.zig` (add `ps4pkg` module with imports `p2z`, plus its test step)

**Interfaces:**
- Consumes: module `p2z` from Task 1.
- Produces:
  - `pub fn isPs4Package(header: []const u8, file_size: u64) bool`
  - `pub const Stats = struct { files: usize, dirs: usize, bytes: u64 };`
  - `pub fn extract(io: std.Io, arena: std.mem.Allocator, input: []const u8, dest: []const u8) !Stats`

- [ ] **Step 1: Write the failing detector tests** in `src/pkg/ps4.zig`

Use a `[0x438]u8` zeroed buffer; assert `false` for short header, wrong magic, `package_size != file_size`, zero `pfs_image_offset`; assert `true` when magic = `{0x7f,'C','N','T'}`, `package_size` (big-endian at `0x430`) equals `file_size`, `pfs_image_offset` (big-endian at `0x410`) = `0x500000`.

- [ ] **Step 2: Wire the `ps4pkg` module in `build.zig` and run the tests**

Add module `ps4pkg` with root `src/pkg/ps4.zig` and `.imports = &.{.{ .name = "p2z", .module = p2z }}`; hook its `addTest` step into `test_step`. Run: `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test -Dtest-filter=ps4`
Expected: FAIL (`isPs4Package` undefined) before Step 3, PASS after Step 5.

- [ ] **Step 3: Implement `isPs4Package`**

Check length ≥ `0x438`, magic, `package_size == file_size`, and `0 < pfs_image_offset < file_size`, all big-endian. One-line comment: why `package_size` distinguishes PS4 from a PS5 raw CNT.

- [ ] **Step 4: Implement `extract`**

`p2z.source.Source.open(io, arena, &.{input})`; on `.fail`, print `p2z.source.describe(fail, &buf)` to stderr and return `error.InvalidPs4Package`. On `.ok`, `defer source.close()`, build `var sources = [_]p2z.source.Source{source}`, `const plan = try p2z.plan.build(arena, &sources)`, `var cancel = std.atomic.Value(bool).init(false)`, then `p2z.extractor.run(arena, io, &sources, &plan, .{ .output = dest, .cancel = &cancel })` with `overwrite = false`. Map `Stats` fields through.

- [ ] **Step 5: Run tests**

Run: `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test -Dtest-filter=ps4`
Expected: PASS.

- [ ] **Step 6: Commit**

`git add src/pkg/ps4.zig build.zig && git commit -m "feat(pkg): add PS4 PKG detection and extraction wrapper"`

---

### Task 3: Dispatch, docs, and end-to-end verification

**Files:**
- Modify: `src/pkgextractor.zig` (header buffer `0x100` → `0x440`; new import `ps4pkg`; dispatch before `pkg.detectKind`; usage text)
- Modify: `docs/getting-started.md` (one line: PS4 PKG support)
- Test: manual CLI verification against the reference manifest

**Interfaces:**
- Consumes: `ps4pkg.isPs4Package` and `ps4pkg.extract` from Task 2.

- [ ] **Step 1: Change the header read and add the dispatch**

Read `[0x440]u8` instead of `[0x100]u8`. Place the PS4 branch immediately after `file_size` is read and **before** `defer file.close(io)` is registered: if `ps4pkg.isPs4Package(&header, file_size)`, close `file` explicitly, call `ps4pkg.extract(io, arena, input, dest_path)`, print `extracted N file(s), M bytes to <dest>`, and return. Keep every existing branch below unchanged (no double close).

- [ ] **Step 2: Build with Zig 0.16**

Run: `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 /home/reng/tools/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseFast`
Expected: PASS, no errors. Confirm `zig-out/bin/pkgextractor` exists.

- [ ] **Step 3: Extract the sample PKG**

Run: `./zig-out/bin/pkgextractor '/home/reng/Downloads/[SPSX]-OneShot.World.Machine.Edition-CUSA34845-USA-GAME-v1.00-9.50+.pkg' -o /tmp/opencode/ps5pcem-ps4-out`
Expected: `extracted 4485 file(s), 1465897453 bytes`.

- [ ] **Step 4: Compare against the reference manifest**

Generate `{size, sha256, relative path}` for `/tmp/opencode/ps5pcem-ps4-out` and diff with `/tmp/opencode/reference-manifest.txt`.
Expected: 4,485 paths, zero size/hash differences except `sce_sys/npbind.dat` (expected 4-byte tail difference per Review Focus).

- [ ] **Step 5: Check the cache cap and commit**

Run `du -sc .zig-cache /tmp/opencode/zig-global-cache-0.16 | tail -1`; expected under 1 GB. Then
`git add src/pkgextractor.zig docs/getting-started.md && git commit -m "feat(pkgextractor): extract PS4 PKGs into a runnable game tree"`
