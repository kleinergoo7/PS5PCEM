# Task 1 report — Measure MISS imports for both ROMs

**Status:** DONE_WITH_CONCERNS

**Inventory artifact:** `.superpowers/sdd/2026-11-19-ps4-first-frame/miss-inventory.md`
(absolute: `/home/reng/projects/ps5_zig_emu/PS5PCEM_PS4Mode/.superpowers/sdd/2026-11-19-ps4-first-frame/miss-inventory.md`)

No source file, index, HEAD, or branch state was modified. No subagents were
dispatched. Only the authoritative trees under `/tmp/opencode/verify-a` and
`/tmp/opencode/verify-b` were used.

## What was done

- Step 1/2: ran `module-info` on each ROM's `eboot.bin` and every
  `sce_module/*.prx`, collected every import whose status mark is `MISS`, and
  parsed each into `{library, NID, kind}`.
- Step 3: recorded both lists (per-module tables + per-ROM totals), the exact
  commands, and the exact `PS5_PS4_MODE=on game-run --app0 <tree> <eboot>`
  link-failure lines into the inventory file.
- Validated the inventory: 555 NID-table rows total (126 + 429), all NIDs
  11 chars, kinds 471 `func` + 84 `object`.

## Per-ROM MISS counts (module-info, occurrences)

### verify-b  (/tmp/opencode/verify-b) — TOTAL 126
| module | MISS |
|---|---:|
| eboot.bin | 126 |
| sce_module/libc.prx | 0 |
| sce_module/libSceFios2.prx | 0 |

### verify-a  (/tmp/opencode/verify-a) — TOTAL 429
| module | MISS |
|---|---:|
| eboot.bin | 98 |
| sce_module/libc.prx | 3 |
| sce_module/libSceAudioLatencyEstimation.prx | 0 |
| sce_module/libSceFace.prx | 5 |
| sce_module/libSceFaceTracker.prx | 17 |
| sce_module/libSceFios2.prx | 1 |
| sce_module/libSceHand.prx | 0 |
| sce_module/libSceHandTracker.prx | 0 |
| sce_module/libSceHeadTracker.prx | 5 |
| sce_module/libSceJobManager.prx | 54 |
| sce_module/libSceNpToolkit2.prx | 148 |
| sce_module/libSceS3DConversion.prx | 98 |

## game-run link failures (exact lines)

- verify-b: 37 `  unresolved eboot.bin: <NID> <library> func` lines (libraries:
  libSceCompanionUtil, libSceInvitationDialog, libSceRtc, libSceNgs2,
  libSceGnmDriver), then `cannot link /tmp/opencode/verify-b/eboot.bin: UnresolvedImport`.
- verify-a: one line `  unresolved sce_module/libSceFios2.prx: hHrGoGoNf+s libSceSysmodule func`,
  then `cannot link /tmp/opencode/verify-a/eboot.bin: RelocationTargetUnavailable`.

## Concerns

1. **`zig build module-info -- <file>` does not work in this checkout.** The
   only installed toolchain is Zig 0.17.1 and `build.zig:34` uses `.ReleaseSafe`,
   which no longer exists in `std.lang.Optimize`
   (`error: no field named 'ReleaseSafe' in enum 'lang.Optimize'`). The exact
   brief command therefore cannot be run as written. The prebuilt
   `./zig-out/bin/module-info` (same `src/module_info.zig`, built before the
   toolchain drift) was used instead; it is functionally the same tool. This is
   the command recorded in the inventory. Fixing `build.zig` is out of scope
   for this read-only task.
2. **module-info MISS count >> game-run unresolved count.** verify-b: 126 vs 37;
   verify-a: 429 vs 1. module-info was run per-file with no provider PRXs, so
   it cannot see guest exports supplied by the bundled `sce_module/*.prx` and
   over-reports imports that `game-run` (full module graph) resolves. This is
   expected from the task's specified invocation, but the two numbers are not
   directly comparable. All 37 verify-b game-run NIDs are a subset of the
   module-info MISS set (verified); verify-a's single NID
   `hHrGoGoNf+s` is among libSceFios2.prx's 1 MISS.
3. **verify-a aborts at a different, earlier failure.**
   `RelocationTargetUnavailable` stops the link before the bulk of MISS imports
   are surfaced, so its game-run output does not enumerate the 429 module-info
   MISS imports.
4. **One verify-b link-failure line was reconstructed.** On every capture,
   stderr's `d88anrgNoKY` unresolved line was byte-interleaved with a buffered
   stdout `[link] ... 673 imports ... <<APPLY>>` line. The NID/library/kind were
   recovered from the wrapped tail and confirmed present as a module-info MISS
   (`0x0000005a5080 MISS d88anrgNoKY libSceGnmDriver/libSceGnmDriver func jump_slot`);
   the reconstruction is annotated in the inventory.
