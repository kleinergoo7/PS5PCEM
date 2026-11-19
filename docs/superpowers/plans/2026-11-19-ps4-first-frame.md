# PS4 first-frame Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get both extracted PS4 sample ROMs past link and to a captured first guest-rendered frame using PS4-only wrappers and wired PS4-mode infrastructure.

**Architecture:** Measure the MISS imports per ROM, register PS4-NID-keyed wrappers/stubs in the existing HLE tables, wire the already-written `ps4_mode/game_hook.zig` into `game_run` so GNM packets reach the shared executor, then iterate on measured walls to the first frame. PS5 paths stay native.

**Tech Stack:** Zig 0.16.0, existing HLE symbol DB, `ps4_mode` bridge, Vulkan backend, Linux/X11 host.

**Spec:** `docs/superpowers/specs/2026-11-19-ps4-first-frame-design.md`

## Global Constraints

- Zig 0.16.0; full `zig build test` stays green.
- PS5 exports and PS5 paths stay native; new exports must be PS4-NID-keyed via `id_override`.
- PS4 hit counters must live in a PS4-only module; do not change `src/hle/trace.zig`.
- No separate PS4 renderer, allocator or memory manager; reuse shared infrastructure.
- Hard Zig cache cap: 5 GB.
- Authoritative extracted trees: `/tmp/opencode/verify-a` (OneShot), `/tmp/opencode/verify-b` (Terraria).

## Review Focus

- PS5 path must remain untouched: no PS5 export, loader or renderer change — pinned by full-suite green and a diff check that only PS4-keyed files changed.
- Both ROMs must link with zero unresolved imports — pinned by `game-run` link output in Tasks 4 and 5.
- Diagnostics must not change shared `trace` — pinned by Task 3's test and diff scope.
- Wrapper classification: value-returning imports must not blindly return zero — pinned by the wall investigation in Tasks 4–6.
- The captured frame must come from the guest draw path, not a synthetic image — pinned by the existing `colored != 0` gate at `src/vulkan/backend.zig:19659` producing `out/first-frame.ppm`.

---

### Task 1: Measure MISS imports for both ROMs

**Files:** create `.superpowers/sdd/2026-11-19-ps4-first-frame/miss-inventory.md` (plan workspace artifact, not committed).

**Interfaces:** Produces: per-ROM list of `{library, NID, kind}` for every unresolved import, plus the exact `game-run` link-failure lines.

- [ ] **Step 1:** Run `module-info` (`zig build module-info -- <file>`) on `/tmp/opencode/verify-b/eboot.bin` and every `sce_module/*.prx`, collect lines beginning `MISS`.
- [ ] **Step 2:** Repeat for `/tmp/opencode/verify-a/eboot.bin` and its `sce_module/*.prx`.
- [ ] **Step 3:** Record both lists with the exact command used for each and the link-failure output from `PS5_PS4_MODE=on game-run --app0 <tree> <eboot>`. Return the file path and a summary count. No source changes.

### Task 2: Wire the PS4 hook into game_run

**Files:** Modify `src/game_run.zig`; if needed, `src/ps4_mode/game_hook.zig`. Test: `zig build test-ps4mode`.

**Interfaces:** Consumes `ps4_mode.game_hook.decideForBlobs`, `configFromEnv`, `startupLine`, `runtime.Config.enabledFor`; `ps4_mode.bridge.runBuffer` / `runDefaultState`. Produces: when PS4 mode is active, the runner bootstraps a `runtime.Session` and lowers the driver default-state preamble into the shared GPU path.

- [ ] **Step 1:** Write a test in `src/ps4_mode/game_hook.zig` asserting `configFromEnv()` with `PS5_PS4_MODE=on` yields `enabledFor(.ps4_gnm) == true`, and without the variable it follows auto policy. Run `zig build test-ps4mode` and watch it fail.
- [ ] **Step 2:** In `src/game_run.zig`, read `PS5_PS4_MODE` once via `configFromEnv()`, call `decideForBlobs(param_sfo_bytes, eboot_bytes)`, print `startupLine`, and when `enabledFor(mode)` is true bootstrap the session and call `bridge.runDefaultState` with caller-owned scratch buffers. No changes inside the PS5 branch.
- [ ] **Step 3:** Run `zig build test-ps4mode` and full `zig build test`; expect PASS with no PS5 regressions.
- [ ] **Step 4:** Commit only those two files: `git commit -m "feat(ps4_mode): wire PS4-only hook into game_run"`.

### Task 3: PS4-only hit counters

**Files:** Create `src/ps4_mode/hits.zig`; modify `src/ps4_mode/root.zig`. Test in `src/ps4_mode/hits.zig`.

**Interfaces:** Produces: `record(name: []const u8)`, `report(buf: []u8) []const u8`, `reset()` — PS4-only counters gated by `PS5_GNM_DIAG`. Must not import or modify `src/hle/trace.zig`.

- [ ] **Step 1:** Write a test asserting two `record` calls for the same name produce a report containing that name and count 2, and that `reset()` clears it. Run `zig build test-ps4mode`; expect failure.
- [ ] **Step 2:** Implement the counters with fixed-size storage and report formatting in `src/ps4_mode/hits.zig`; export from `root.zig`.
- [ ] **Step 3:** Run `zig build test-ps4mode`; expect PASS. Confirm `git diff` touches no file under `src/hle/trace.zig`.
- [ ] **Step 4:** Commit: `git commit -m "feat(ps4_mode): add PS4-only wrapper hit counters"`.

### Task 4: Close Terraria's PS4 imports

**Files:** Modify `src/hle/libs/ps4_title_stubs.zig` and/or a new PS4 wrapper module registered from `src/hle/root.zig`.

**Interfaces:** Consumes Task 1's Terraria MISS list and Task 3's `hits.record`. Produces: zero unresolved imports for Terraria.

- [ ] **Step 1:** For each MISS NID, classify per spec: void/idempotent → benign stub; value-returning → plausible value; allocation/sync/data → wrapper to shared implementation; no shared counterpart → minimal PS4 logic. Record the classification in the task report.
- [ ] **Step 2:** Register the NIDs via `id_override` in PS4-only tables; each new entry calls `hits.record`. Do not modify any PS5 export.
- [ ] **Step 3:** Build and run `PS5_PS4_MODE=on game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin`; expect no `unresolved` lines. Run full `zig build test`.
- [ ] **Step 4:** Commit only PS4 files: `git commit -m "feat(ps4): close Terraria import closure"`.

### Task 5: Close OneShot's PS4 imports

**Files:** same PS4-only registration files as Task 4.

**Interfaces:** Consumes Task 1's OneShot MISS list and Task 4's registration pattern.

- [ ] **Step 1:** Classify and register OneShot's MISS NIDs, including the `libSceSysmodule` alias and `libSceCompanionUtil`, using the same PS4-only path.
- [ ] **Step 2:** Run the same `game-run` command against `/tmp/opencode/verify-a`; expect no `unresolved` lines. Run full `zig build test`.
- [ ] **Step 3:** Commit: `git commit -m "feat(ps4): close OneShot import closure"`.

### Task 6: Iterate to first guest frame

**Files:** only PS4-specific wrapper/stub files identified by the wall traces; no PS5 files.

- [ ] **Step 1:** Run Terraria with `PS5_PS4_MODE=on PS5_CAPTURE_FIRST_FRAME=1 PS5_GNM_DIAG=1 game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin`.
- [ ] **Step 2:** If no `out/first-frame.ppm` is produced or the run crashes/hangs, read the PS4 hit report; fix only the wrapper at the top of that trace, respecting the classification rule (no blind zero for value-returning imports). Re-run. Repeat until a guest frame is captured or a genuine shared-infrastructure blocker is proven.
- [ ] **Step 3:** Repeat Steps 1–2 for OneShot.
- [ ] **Step 4:** Record the exact command, frame file path and pixel summary for each ROM in the task report; run full `zig build test`; commit PS4-only changes with `git commit -m "feat(ps4): reach first guest frame"`.
- [ ] **Step 5:** Report honestly if a ROM stops at a wall that needs shared infrastructure changes — do not change PS5 paths to force success.
