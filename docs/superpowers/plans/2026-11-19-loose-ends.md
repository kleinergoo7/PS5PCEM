# Loose ends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the `npbind.dat` tail, both HLE test failures, and the cache cap using many small subagent tasks.

**Architecture:** Three independent problem domains (npbind, kernel_memory, pad) each get a read-only investigator, then a single-file fix agent in its own git worktree. A fourth agent handles the cache script. The coordinator integrates and verifies. Spec is the authority; Stage 2 briefs are written from Stage 1 verdicts.

**Tech Stack:** Zig 0.16.0 (`/home/reng/tools/zig-x86_64-linux-0.16.0/zig`), bash, existing superpowers subagent harness.

**Spec:** `docs/superpowers/specs/2026-11-19-loose-ends-design.md`

## Global Constraints

- Zig **0.16.0** only; build with `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`.
- ps5pcem cache stays **under 1 GB** (1,000,000 KB).
- No new runtime dependency; no changes outside each task's listed files.
- Fix agents work in separate worktrees under `/home/reng/projects/ps5_zig_emu/.worktrees/`; never edit another domain's files.
- Read-only investigators must not modify the working tree, index, HEAD, or any source file.

## Review Focus

- `npbind.dat` final 4 bytes must match the authoritative decryptor on **both** sample ROMs — pinned by Task 5's two CLI diffs.
- Batch-map with `start=0, offset=0x10000, length=0x20000` must succeed instead of returning `0x8002000d` — pinned by Task 6 against the named `kernel_memory` test.
- The unmap following that batch map must succeed instead of `0x80020016` — pinned by the same Task 6 test.
- Primary-user pad port must be `128`, not `129` — pinned by Task 7 against the named `pad` test.
- A full build must leave ps5pcem cache under 1 GB — pinned by Task 4's script check and Task 8's final measurement.

---

### Stage 1 — read-only investigations (parallel)

### Task 1: Determine the authoritative `npbind.dat` tail

**Files (read only):** `vendor/pkg2zar/core/src/source.zig` (`sceEntryData`, ~255–290), `vendor/pkg2zar/core/src/crypto.zig` (`aesCbcDecrypt`, ~65), `/tmp/opencode/shad-keys.h`, `docs/superpowers/specs/2026-11-18-ps4-pkg-extraction-design.md`.

**Interfaces:**
- Consumes: nothing.
- Produces: verdict file `.superpowers/sdd/2026-11-19-loose-ends/npbind-verdict.md` with (a) which decryptor is correct, (b) exact code line to change, (c) expected last 4 bytes for each sample ROM.

- [ ] **Step 1:** Read `sceEntryData` and note that it zero-pads the final cipher block; read shadPS4Plus's `aesCbcCfb128DecryptEntry` (source: `https://raw.githubusercontent.com/AzaharPlus/shadPS4Plus/ShadPs4Plus/src/core/crypto/crypto.cpp`) and note how it sizes the cipher buffer.
- [ ] **Step 2:** Regenerate a reference extraction with `/tmp/opencode/squashfs-root/AppRun` for both ROMs in `/home/reng/Downloads/ps4roms/` into `/tmp/opencode/ref-a` and `/tmp/opencode/ref-b`, and dump the last 16 bytes of each `sce_sys/npbind.dat`.
- [ ] **Step 3:** Write the verdict file; do not edit any source. Return the verdict text in the final message.

### Task 2: Root-cause the kernel_memory batch-map failure

**Files (read only):** `src/hle/libs/kernel_memory.zig`, especially the test at `:3834` and the batch-map/unmap implementations.

**Interfaces:**
- Consumes: nothing.
- Produces: verdict file `.superpowers/sdd/2026-11-19-loose-ends/kernel-memory-verdict.md` naming the exact function and condition that returns `0x8002000d` / `0x80020016` for the failing test.

- [ ] **Step 1:** Run `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-hle` and capture the full failure block.
- [ ] **Step 2:** Trace the failing operations (`map_direct start=0 offset=0x10000 length=0x20000 prot=3 flags=0`, then `unmap start=0x1000000000 length=1 flags=0x10`) to the validating code; identify the exact rejected condition.
- [ ] **Step 3:** Write the verdict file; do not edit source. Return it in the final message.

### Task 3: Root-cause the pad port off-by-one

**Files (read only):** `src/hle/libs/pad.zig`, test at `:547`.

**Interfaces:**
- Consumes: nothing.
- Produces: verdict file `.superpowers/sdd/2026-11-19-loose-ends/pad-verdict.md` naming the exact expression that yields 129.

- [ ] **Step 1:** Read the failing test and the primary-user port allocation code it exercises.
- [ ] **Step 2:** Identify the exact off-by-one (enum value, index, or 1-based/0-based conversion) that produces 129.
- [ ] **Step 3:** Write the verdict file; do not edit source. Return it in the final message.

### Task 4: Cache-capped build script

**Files:**
- Create: `scripts/build-capped.sh`
- Modify: `docs/getting-started.md` (one line pointing at the script)

**Interfaces:**
- Consumes: nothing.
- Produces: executable script taking the same arguments as `zig build`.

- [ ] **Step 1:** Write `scripts/build-capped.sh` that sets `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-capped-global`, passes `--cache-dir /tmp/opencode/zig-capped-local` plus all `"$@"` to `/home/reng/tools/zig-x86_64-linux-0.16.0/zig build`, then sums both dirs with `du -sk`.
- [ ] **Step 2:** If the sum exceeds `1000000` KB, delete the local cache dir, print `cache trimmed`, and re-check that the remaining total is under the cap. Exit non-zero if still over.
- [ ] **Step 3:** Verify: `scripts/build-capped.sh test-ps4` prints a total under `1000000` KB and exits 0.
- [ ] **Step 4:** Commit only `scripts/build-capped.sh` and `docs/getting-started.md`: `git commit -m "build: add cache-capped build wrapper"`.

---

### Stage 2 — narrow fixes (parallel, separate worktrees)

Stage 2 briefs are written by the coordinator from the matching Stage 1 verdict. Each fix agent gets: the verdict path, the exact file it may edit, the exact test command, and the constraint not to touch any other domain's files.

### Task 5: Fix `npbind.dat` in the vendored core

**Files:** Modify only `vendor/pkg2zar/core/src/source.zig` and `vendor/pkg2zar/NOTICE`.

**Interfaces:** Consumes Task 1's verdict; produces corrected NP entry bytes.

- [ ] **Step 1:** Write the verdict's expected tail bytes as an assertion in a throwaway check script under `/tmp/opencode/` (not committed); run it and watch it fail on the current binary.
- [ ] **Step 2:** Apply the single-line change in `sceEntryData` identified by Task 1; append the divergence note to `vendor/pkg2zar/NOTICE`.
- [ ] **Step 3:** Rebuild with Zig 0.16 and re-extract both ROMs; run the throwaway check; expect PASS on both.
- [ ] **Step 4:** Commit only the two listed files: `git commit -m "vendor: correct NP entry tail decryption"`.

### Task 6: Fix kernel_memory batch map

**Files:** Modify only `src/hle/libs/kernel_memory.zig`.

**Interfaces:** Consumes Task 2's verdict.

- [ ] **Step 1:** Run `zig build test-hle` and confirm the named test fails with `0x8002000d` / `0x80020016`.
- [ ] **Step 2:** Apply the minimal root-cause fix named in Task 2's verdict.
- [ ] **Step 3:** Run `zig build test-hle`; expect both failures gone and no new failures.
- [ ] **Step 4:** Commit only that file: `git commit -m "fix(hle): accept batch map with zero base and offset"`.

### Task 7: Fix pad primary-user port

**Files:** Modify only `src/hle/libs/pad.zig`.

**Interfaces:** Consumes Task 3's verdict.

- [ ] **Step 1:** Run `zig build test-hle` and confirm the named test fails with `expected 128, found 129`.
- [ ] **Step 2:** Apply the minimal root-cause fix named in Task 3's verdict.
- [ ] **Step 3:** Run `zig build test-hle`; expect that test green and no new failures.
- [ ] **Step 4:** Commit only that file: `git commit -m "fix(hle): correct primary pad port to 128"`.

---

### Stage 3 — integration

### Task 8: Integrate, verify, review

**Files:** none directly; merges Tasks 4–7 worktrees into `ps4-mode`.

- [ ] **Step 1:** Merge each fix worktree in turn; resolve nothing silently — report any conflict to the user.
- [ ] **Step 2:** Run `zig build test` with Zig 0.16; expect all suites green.
- [ ] **Step 3:** Re-extract both ROMs with the integrated binary and compare full manifests against the fresh reference extractions from Task 1; expect zero differences including `npbind.dat`.
- [ ] **Step 4:** Measure cache; expect under 1,000,000 KB.
- [ ] **Step 5:** Dispatch one fresh reviewer on the merged range; fix Critical/Important findings with a RED→GREEN pass, record minors.
