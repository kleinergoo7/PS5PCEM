# Task 3 report — PS4-only hit counters

## Status

DONE. RED→GREEN completed; `zig build test-ps4mode` and full `zig build test` both pass. Only the two allowed files were committed. `src/hle/trace.zig` was not imported, modified, or otherwise touched.

## What was produced

`src/ps4_mode/hits.zig` (new) exports the exact interfaces later tasks consume:

- `pub fn record(name: []const u8) void` — count one hit of a wrapper name.
- `pub fn report(buf: []u8) []const u8` — render `"<name> <count>\n"` lines into caller-owned `buf`, returning the written slice.
- `pub fn reset() void` — clear all counts.
- plus a small gate seam: `pub fn setEnabled(value: bool) void` (documented, mirrors `hle/trace.zig`'s `setEnabled` pattern).

`src/ps4_mode/root.zig` (modified) exports `pub const hits = @import("hits.zig");` and references it in the module test block so its test is collected.

## Implementation notes

- Fixed-size storage: `pub const capacity: usize = 128` slots of `{ name: []const u8, count: u64 }`. Names are borrowed static strings (the way a trace thunk borrows its entry-point name), so no allocation. A new name claims the next free slot; hits beyond capacity are dropped rather than displacing an existing count.
- `report` uses `std.fmt.bufPrint` (the house pattern in this repo) and breaks cleanly on a short buffer, so truncation never writes out of bounds.
- RED→GREEN:
  1. Wrote the prescribed test first (two `record` calls for one name → report contains `"sceKernelAllocateMemory 2"` → `reset()` clears it), wired the export, ran `zig build test-ps4mode` → failure: `error: use of undeclared identifier 'reset'` (exit 1).
  2. Implemented the counters; first GREEN attempt failed to compile because `std.posix.getenv` does not exist in the pinned Zig 0.16 toolchain (the unreferenced copy in `runtime.zig` was never compiled). Fixed by gating through the already-seeded `game_hook.configFromEnv().diag` instead of reading the environment directly.
  3. Re-ran `zig build test-ps4mode` → exit 0 (PASS).

## Gating by PS5_GNM_DIAG

Counting is gated by the existing diagnostics flag: `isEnabled()` lazily reads `game_hook.configFromEnv().diag` on first use (game_run seeds `PS5_GNM_DIAG` into `game_hook` at src/game_run.zig:621 before any PS4 wrapper runs). `setEnabled(bool)` overrides that value — the test calls `setEnabled(true)` so it is deterministic regardless of the process environment. This keeps the gate PS4-only and avoids adding any `std.posix.getenv` / libc dependency to this module.

## Verification

- `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode` → exit 0.
- `... zig build test` (full suite) → exit 0, no PS5 regressions.
- `git diff --name-only -- src/hle/trace.zig` → empty (no changes).
- Commit `d838101 feat(ps4_mode): add PS4-only wrapper hit counters` contains exactly `src/ps4_mode/hits.zig` and `src/ps4_mode/root.zig`.

## Concerns / skipped

- The gate is read through `game_hook.configFromEnv().diag`, which is cached on first `record`. A caller that seeds the diag flag *after* the first hit would not change the gate; in practice game_run seeds it before wrappers run, and `setEnabled` is available for explicit overrides. The test uses that override, so it does not exercise the env-driven default.
- No concurrency control: like `hle/trace.zig` this is a cheap diagnostic, so a concurrent `record`/`report` can observe a torn count. Counters are approximate by design.
- Did not add a name-count accessor or per-name query; `report` is the only read surface, as specified. No tests beyond the brief's required one were added.
