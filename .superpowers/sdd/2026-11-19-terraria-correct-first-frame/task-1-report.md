# Task 1 report — Ordered per-draw resource capture

Status: DONE

## What changed

- `src/ps4_mode/gcn_resources.zig`
  - Defined `ProgramPair = struct { vertex: u64 = 0, pixel: u64 = 0 }`,
    `max_draws_per_capture = 8`, `max_capture_queue = 8`, and `Capture`
    (`draws: [max_draws_per_capture]Resources`, `count: usize`).
  - Replaced the global last-DCB-wins slot (`captured_resources` / `captured_valid`
    / `captured()`) with an 8-entry `Capture` ring plus head/len/draw-cursor:
    `publish(Capture)` appends, `nextDrawResources() ?Resources` drains in
    submit/draw order, `resetCapture()` clears all state. Spin-lock kept; no
    allocation. Exhausted captures are dropped while a newer one exists; a
    final capture with more draws than snapshots clamps to its last snapshot;
    null only when nothing was published. Ring-full drops the oldest capture.
  - `capture()` now returns `Capture`: the packet walker copies the running
    `Resources` at each `DRAW_INDEX_AUTO` (0x2d), capped at 8. A DCB with no
    draw packet keeps the whole-stream result in `draws[0]` (count = 1).
    Added the two brief tests (built from real Terraria dwords) plus a
    rewritten FIFO drain test and `psImage` helper; adapted the three existing
    tests that consumed the old `Resources` return.
- `src/ps4_mode/root.zig`: re-exported `ProgramPair`.
- `src/hle/libs/gnm_compat.zig`: the submit call was already the required
  `publish(capture(slice))` form; updated only its comment to describe ordered
  per-draw snapshots (no functional change).
- `src/vulkan/backend.zig`: `ps4GraphicsScalars`, `ps4SampledImageDescriptor`,
  and `stagePs4GraphicsSampledImage` now take a `Resources` by value;
  `drawPs4FixedColor` calls `nextDrawResources()` once at entry, returning
  `Error.UnsupportedGraphicsState` when nothing was published, and passes the
  snapshot through. Gate tests updated to reset before publish and to assert
  `stagePs4GraphicsSampledImage` returns null with the compat flag off.

No changes to `src/gpu/**` or any shared HLE implementation. No allocation,
no new dependency, no PS5-path change. Multi-draw texture selection was NOT
added (deferred to the later task per the brief).

## TDD evidence

- Wrote the two brief tests first; `zig build test-ps4mode` failed to compile
  with `use of undeclared identifier 'nextDrawResources'` (2 errors).
- Implemented; both new tests and all existing tests pass.

## Tests (Zig 0.16 at /home/reng/tools/zig-x86_64-linux-0.16.0/zig)

- `zig build test-ps4mode`: exit 0. Direct test binary: `All 54 tests passed.`,
  including `per-draw snapshots keep distinct PS textures`,
  `capture FIFO is ordered for equal program pairs`, and
  `publish/nextDrawResources/reset drain DCB snapshots at the submit boundary`.
- `zig build test`: exit 0. Vulkan binary: `275 passed; 1 skipped; 0 failed.`,
  including all three PS4 gate tests. (The build runner prints `failed command:
  ...` lines for several test artifacts — this is pre-existing harness output;
  each binary itself exits 0 and reports no failures.)
- PS5 gate: gate tests pass with `ps4_compat_enabled = false`; the new
  `stagePs4GraphicsSampledImage(... ) == null` assertion is covered by
  `PS4 sampled-image staging is gated off for PS5 draws` (OK).
- Global Zig cache: 107 MB (under the 5 GB cap).

## Commit

`feat(ps4): carry GPU resources per draw instead of last-DCB-wins`

## Concerns / not checked

- Ring-full behavior (>8 pending captures) drops the oldest capture and resets
  the draw cursor to 0; a partially consumed new head could be re-served. Not
  exercised by tests or by Terraria's submit cadence — revisit if a title ever
  queues more than 8 unconsumed captures.
- `drawPs4FixedColor` consumes one snapshot at entry (per the brief), before it
  knows whether a color target exists; a draw that bails out early still
  consumes its snapshot. Clamping keeps later draws fed with the last snapshot,
  so no starvation, but this was not validated under a real multi-DCB frame.
- Snapshots are running accumulations of `Resources`; a per-draw snapshot
  includes prior draws' bindings in the same DCB. Correct for the single-T#
  Terraria fixture; distinguishing multiple T#s within one draw remains the
  later task and was not verified here.
