# PS4 first-frame bring-up using PS4-only wrappers — design

Date: 2026-11-19

## Intent

Get an extracted PS4 game to its **first rendered frame** by resolving the PS4
imports it actually needs, via wrappers that live only on the PS4 side of the
HLE boundary. PS5 code paths stay native and unchanged. This continues the
shared-infrastructure rule already documented in `docs/ps4-mode.md`.

## Why

Extraction is solved: both sample PKGs unpack to valid decrypted SELFs. Both
games currently fail at link time on unresolved PS4 NIDs, before any PS4
graphics code is exercised. The repository already has the right mechanism —
`src/hle/libs/ps4_heap.zig` wraps PS4-specific imports onto shared
implementations, and `src/hle/libs/ps4_title_stubs.zig` registers measured MISS
NIDs — so the missing work is import closure, not a second emulator.

## Goals / non-goals / anti-goals

- Goals: both sample ROMs link with zero unresolved imports; at least one reaches
  a captured first frame; no change to PS5 registration, loader, HLE or renderer
  behaviour outside PS4-keyed entries.
- Non-goals: playable gameplay, retail PSN decryption, full PS4 HLE coverage, a
  separate PS4 renderer or allocator.
- Anti-goals: inserting wrappers into PS5 paths, duplicating shared subsystems
  "just in case", or implementing NIDs no game imports.

## Constraints

- Zig 0.16.0; full `zig build test` stays green.
- PS5 exports stay native; any new export must be keyed by a PS4 identifier
  (`id_override`) so it cannot shadow a PS5 import.
- Zig cache cap: 5 GB.
- Success criterion fixed by the user: **first rendered frame**, not gameplay.

## Approaches considered

1. Stub every MISS NID with a success return — fastest, but crashes and bad
   rendering become hard to attribute; rejected as the only method.
2. Implement real PS4 libraries up front — rejected: speculative work before
   knowing which imports the games actually exercise.
3. **Measure MISS imports, wrap at the PS4 export boundary, classify stubs, and
   iterate to the first frame — chosen.** Minimum PS4-specific code, maximum
   reuse of shared HLE/GPU/memory infrastructure.

## Design

1. **Measure.** For each sample ROM, run the existing `module-info` tool over the
   `eboot.bin` and its `sce_module/*.prx` files, and record `MISS` NIDs per
   library. Use the link-failure logs from `game-run` as the second source.
2. **Register PS4-only.** Add the measured NIDs to the existing compat tables
   (`ps4_title_stubs.zig` for benign gaps, or a PS4-only wrapper module beside
   `ps4_heap.zig` where a shared implementation exists). Entries use
   `id_override`, so PS5 resolution is untouched.
3. **Classify before stubbing:**
   - void/idempotent commands and status queries → benign success stub;
   - calls returning pointers, sizes or handles → minimal plausible value;
   - allocation, synchronisation and data-providing calls → wrapper that
     translates PS4 layout and calls the shared implementation;
   - only where no shared counterpart exists → small PS4-specific logic.
4. **Make walls visible.** Each new PS4 wrapper/stub records its name and hit
   count under the existing diagnostics gate. A "wall" is a crash, a hang, no
   captured frame, or a captured frame that is blank/uniform. The last N PS4
   calls are the debugging entry point.
5. **Iterate per game.** Start with the smaller ROM (Terraria). For each wall,
   fix only the wrapper named by the trace, re-run, and stop when
   `PS5_CAPTURE_FIRST_FRAME=1 PS5_PS4_MODE=on game-run --app0 <tree> <eboot>`
   produces `out/first-frame.ppm` from the guest draw path. Then repeat for
   OneShot.
6. **Keep shared flow intact.** GNM packets still go through `gnm_packets.zig`
   into the shared GPU executor; SFO through the shared loader; audio and heap
   through shared HLE. No PS4-only renderer or memory manager.

## Verification

- Full `zig build test` green (PS5 suites unchanged).
- Both ROMs link with zero unresolved imports.
- First-frame capture produced for at least one ROM, with a note on its pixel
  content; blank/uniform frames are reported, not silently called success.
- Cache stays under 5 GB; results recorded with exact commands.

## Settled by the coordinator

- **Verification host:** the current Linux/X11 machine (`DISPLAY=:0.0`, Vulkan
  renderer). `game-run` already launches here and fails at link, so it is a
  usable bring-up host. If the GPU/swapchain cannot produce a later frame, that
  is reported as an environmental blocker, not silently accepted as success.
- **Diagnostics mechanism:** PS4-only hit counters, not changes to the shared
  `trace` module. PS5 instrumentation stays untouched. This is the coordinator's
  call, consistent with "PS5 always native".
- **Authoritative extracted trees:** `/tmp/opencode/verify-a` (OneShot) and
  `/tmp/opencode/verify-b` (Terraria) — the final byte-verified extractions.
  Other `/tmp/opencode` trees (`ref-*`, `final-*`, `terraria-*`) are older or
  reference-only and must not be used for MISS measurement.

## Left to the builder

Exact MISS lists per ROM; per-NID classification; iteration order within a game;
names for new diagnostics flags; whether a blank captured frame counts as a
wall for the specific game being tested.

## Author decision

**Wiring `ps4_mode` into `game_run` is in scope.** The author chose to include
narrow, PS4-keyed wiring so the bridge is live; the PS5 native path must remain
unchanged. Concretely, `PS5_PS4_MODE` must be resolved in the launcher/runner
(presently it is read only inside `ps4_mode/runtime.zig`), and when enabled the
runner must call `ps4_mode/bridge.zig` so GNM packets reach the shared GPU
executor. This expands the file set to include `src/game_run.zig` and the
bridge, but does not license a separate PS4 renderer.
