# Task 4 report — close Terraria's PS4 imports

## Status

DONE. Terraria link closure is complete: `game-run` reports zero `unresolved`
lines and no `cannot link`, reaching guest execution; `zig build` and full
`zig build test` both exit 0. The commit contains the new PS4 wrapper module and
the PS4-only registration/wiring files.

## Queue and scope

The implementation queue is the **37 NIDs game-run enumerates as unresolved** for
Terraria (verify-b), verbatim from `miss-inventory.md` lines 180–216 — including
`d88anrgNoKY`, reconstructed from the interleaved terminal artifact. The larger
126-entry module-info MISS list was used only as a cross-check, not registered up
front, per the controller ruling. No OneShot (verify-a) work is in scope.

All 37 are function-kind imports. A grep of `src/**/*.zig` confirmed none of the
37 identifiers is registered anywhere, so no implementation — shared or otherwise
— exists under any of these PS4 NIDs. The spec's "no shared counterpart → minimal
PS4 logic" fallback therefore applies to every entry, and there is no risk of
shadowing a PS5 export when registering under `id_override`. For the GNM-driver
imports in particular, wiring them to the shared AGC/GNM translation path is
deferred to first-frame iteration (Task 6), not done here.

## Classification (per NID)

Legend for *Class*:

- **benign** — presumed void/idempotent setup, teardown or setter; benign success.
- **status** — presumed value-returning status/query; the chosen value is the
  deliberate plausible minimum (SCE_OK / not-active / not-connected), not a blind
  zero.
- **no shared counterpart** — the operation may be sync/data/alloc in nature,
  but nothing is registered under the NID and no shared counterpart exists to
  wrap, so the spec's fallback is minimal PS4 logic returning SCE_OK. Wrapping
  the shared AGC/GNM path for these is deferred to Task 6.

NID→function/signature mappings were **not available**: module-info and the
game-run link output expose only library, NID and symbol kind, not a function
name. Every class below is therefore an *operation-category heuristic* derived
from the library name, not a verified function identity; no row claims a specific
function. Because no identifier in this set resolves to a shared implementation,
the "no shared counterpart → minimal PS4 logic" fallback governs all 37; the
benign/status rows merely describe the presumed shape of the chosen minimal
answer. Output structs, where any are passed by pointer, are left untouched
(zero-initialised by the guest). Return value `0` is SCE_OK / not-active across
all groups.

| # | NID | Library | Class | Chosen value / behaviour | Rationale |
|---:|---|---|---|---|---|
| 1 | IPN-FRSrafk | libSceCompanionUtil | benign | 0 | Companion-util class; init/idempotent category; minimal logic. |
| 2 | xb1xlIhf0QY | libSceCompanionUtil | benign | 0 | Companion-util class; notify/teardown category; minimal logic. |
| 3 | H1fYQd5lFAI | libSceCompanionUtil | status | 0 | Companion-util class; query category; plausible min 0. |
| 4 | cE5Msy11WhU | libSceCompanionUtil | benign | 0 | Companion-util class; setter category; minimal logic. |
| 5 | 9+g9iOq+7kg | libSceInvitationDialog | benign | 0 | Invitation-dialog class; setter category; minimal logic. |
| 6 | 8XKR6wa64iQ | libSceInvitationDialog | benign | 0 | Invitation-dialog class; post category; minimal logic. |
| 7 | B6HVJtDYxEE | libSceInvitationDialog | status | 0 | Invitation-dialog class; query category; plausible min 0. |
| 8 | XvA5KS56wcs | libSceInvitationDialog | benign | 0 | Invitation-dialog class; close/teardown category; minimal logic. |
| 9 | 0zU0G+wiVLA | libSceInvitationDialog | status | 0 | Invitation-dialog class; query category; plausible min 0. |
| 10 | NxEI1KByvCI | libSceRtc | status | 0 | RTC class; query category; plausible min 0, pointer output left as-is. |
| 11 | t9T0QM17Kvo | libSceNgs2 | status | 0 | NGS2 class; query/op category; plausible min 0. |
| 12 | QhnyReteJ1M | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 13 | jiItzS6+22g | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 14 | aj3L-iaFmyk | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 15 | W1Etj-jlW7Y | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 16 | aPIZJTXC+cU | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 17 | 7qZVNgEu+SY | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 18 | 26PM5Mzl8zc | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 19 | RU74kek-N0c | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 20 | iCO804ZgzdA | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 21 | PVT+fuoS9gU | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 22 | UoYY0DWMC0U | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 23 | H7-fgvEutM0 | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 24 | iBt3Oe00Kvc | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 25 | qpGITzPE+Zc | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 26 | b08AgtPlHPg | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 27 | gObODli-OH8 | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 28 | +xuDhxlWRPg | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 29 | f85orjx7qts | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 30 | HHo1BAljZO8 | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 31 | jtkqXpAOY6w | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 32 | u9YKpRRHe-M | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 33 | 4UFagYlfuAM | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 34 | xeTLfxVIQO4 | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 35 | 9thMn+uB1is | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 36 | d88anrgNoKY | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |
| 37 | TLV4mswiZ4A | libSceGnmDriver | no shared counterpart | 0 | Opaque NID; GNM-driver class; minimal logic, SCE_OK. |

The 26 GNM-driver NIDs belong to the low-level driver library (the class covers
draw/submit/validate/register/map/invalidate and query operations as a category —
the individual functions are not identified by any available output). None is
registered under its NID and none has a shared counterpart to wrap, so each takes
the spec's fallback: **no shared counterpart → minimal PS4 logic**, answering
SCE_OK. This is deliberately *not* labelled "benign no-op": some of these
operations are plausibly sync/data/alloc in nature, and asserting otherwise
without a signature would be a guess. Routing them through the shared AGC/GNM
translation path, where the title actually needs real command execution, is
deferred to first-frame iteration (Task 6).

## Implementation

- New PS4-only module `src/hle/libs/ps4_terraria_stubs.zig` holds the 37-entry
  table. Each entry is registered with `id_override` = its exact PS4 NID, so no
  PS5 import is shadowed (none of the 37 collides with any existing export).
- Every entry gets a distinct thunk (generated per entry with `trace.wrap`) whose
  body calls `ps4_mode.hits.record(<nid>)` and returns SCE_OK (0). Recording is
  gated by PS5_GNM_DIAG in `hits.zig`, as designed in Task 3; the link-closure
  verification run does not set that flag, so recording is structurally present
  but a no-op there by design.
- Registered from `src/hle/root.zig::registerAll` alongside the other PS4 stubs;
  the module is referenced in that file's test block so its self-test is collected.
- A self-test registers the table into a fresh `Database` and asserts each of the
  37 identifiers resolves via `findById`.
- Module-boundary wiring: `ps4_mode` is a standalone build module, and the `hle`
  module cannot reach a file outside its own root by relative import. To let the
  PS4 wrapper call Task 3's counter, `ps4_mode` is imported as a proper module by
  both `hle` and `game-run` (the latter switched from a relative
  `@import("ps4_mode/root.zig")` to the module import so a file is not present in
  two modules). These are build-wiring lines only — no PS5 export or shared
  subsystem behaviour changed.

## Verification

All commands used the pinned toolchain
`/home/reng/tools/zig-x86_64-linux-0.16.0/zig` with
`ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`.

- `zig build` → exit 0.
- `PS5_PS4_MODE=on ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin`:
  `grep -ci unresolved` → **0**; no `cannot link` line. Link summary applied all
  imports, `loaded .../eboot.bin`, `entering guest process`. The process later
  aborts in guest dispatch (SIGABRT) — a runtime fault beyond link closure,
  left to Task 6's first-frame iteration.
- `zig build test` → exit 0. The `failed command:` lines in its log are diagnostic
  output from tests that spawn deliberately-failing child processes / contained
  guest faults; the build step itself exits 0.
- `zig build test-hle -Dtest-filter="every Terraria NID"` → exit 0; the self-test
  is present in the hle test binary (confirmed via `strings`).

## Concerns / skipped

- Shared-file wiring: `build.zig` (add `ps4_mode` module import to `hle` and
  `game-run`) and `src/game_run.zig` (relative `@import("ps4_mode/root.zig")` →
  module `@import("ps4_mode")`) were needed for the PS4 wrapper to call Task 3's
  counter across the module boundary. These are import-edge lines only; no PS5
  export or shared subsystem behaviour changed. They are included in the commit,
  which is broader than a strict reading of "only PS4 files" — flagged for the
  controller.
- All 37 stubs answer SCE_OK (0) under the "no shared counterpart → minimal PS4
  logic" fallback, not because every operation was proven benign — the NIDs are
  opaque and only operation-category heuristics were available. If a
  value-returning or sync/data import is actually consumed on the first frame, it
  may need a title-specific value or a real shared-path wrapper — out of scope
  here and part of Task 6.
- Hits recording is gated by PS5_GNM_DIAG; the link-closure run does not set it,
  so `hits.report` was not exercised in the verification run (only the call site
  is present). Task 3's own test covers the counter.

## Fix round 1

**What changed (docs only).** Addressed the reviewer's Important finding that the
report asserted "alloc/sync/data — none occur here" while calling the 26
GNM-driver NIDs benign no-ops — an internally inconsistent, library-name guess.

- Removed the contradictory `alloc/sync/data — none occur here` legend line and
  the `there was no allocation/sync/data import with a shared counterpart to
  wrap` claim in *Queue and scope*.
- Added an explicit `no shared counterpart → minimal PS4 logic` class to the
  legend and reclassified all 26 `libSceGnmDriver` rows (#12–#37) into it, with a
  note that wrapping the shared AGC/GNM path is deferred to first-frame iteration
  (Task 6).
- Stated plainly that NIDs are opaque — module-info and link output expose only
  library, NID and kind — so every class is an operation-category heuristic, not
  a verified function identity. Removed the guessed per-row function labels
  ("GNM state/draw setup; no-op", "GNM capture/status query") and replaced them
  with the category statement.
- Rewrote the summary below the table and the matching *Concerns* bullet so
  nothing asserts "benign" for sync/data-shaped operations. Also softened the
  non-GNM rationales to operation-category phrasing so no row implies a verified
  function identity.

**No code changed.** `src/hle/libs/ps4_terraria_stubs.zig`, `src/hle/root.zig`,
`build.zig` and `src/game_run.zig` were not touched; commit `43af013` is unchanged.
This report is gitignored and produces no new commit, as requested.

**Tests unaffected.** This is a documentation-only change, so no re-run is
needed. The previously reported results stand: `zig build` exit 0, game-run
`unresolved` count 0 with no `cannot link`, and full `zig build test` exit 0.
