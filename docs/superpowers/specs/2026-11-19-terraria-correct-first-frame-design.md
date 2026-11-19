# Correctly rendered first frame for PS4 Terraria — design

Date: 2026-11-19
Status: DRAFT (awaiting builder check and partner approval)

## Intent

Terraria currently produces a first frame, but it is a diagnostic image: a
solid `#FF4019` triangle drawn by a PS4-gated probe shader with synthetic
quad corners and constant UV. The user wants a **correctly rendered first
frame** — real Terraria content sourced from the guest's own geometry,
shaders, and textures — while keeping every PS5 path native and unchanged.

## Goals

- The first rendered frame of Terraria shows real guest-sourced pixels: guest
  vertex data determines position, guest VINTRP/PARAM data determines UV, and
  the captured T# texture supplies color.
- The result is deterministic across repeated runs (no run-to-run black
  frames or arbitrary texture selection).
- A hermetic PS4-only test reproduces the first frame's draw and asserts the
  output contains real textured content, so progress is measurable without a
  full game run.
- All new behavior is PS4-gated; PS5 output is byte-identical with
  `ps4_compat_enabled = false`.

## Non-goals

- Playable gameplay, input, audio, save data, or later frames.
- Full GCN compiler correctness for arbitrary PS4 titles.
- Replacing or restructuring the shared Vulkan renderer.
- Fabricating a frame: every pixel must come from the existing backend
  capture/presentation path using guest-sourced data.

## Anti-goals (what makes this fail even if it draws something)

- A solid-color probe triangle, a checkerboard, or any synthetic texture.
- Synthetic quad corners or hardcoded `gl_Position` left in the final path.
- UV hardwired to `(0,0)`, sampling one texel.
- A frame that only appears under one capture timing (the current state).

## Constraints

- Zig 0.16.0 (`/home/reng/tools/zig-x86_64-linux-0.16.0/zig`), global cache
  `/tmp/opencode/zig-global-cache-0.16`, 5 GB cap.
- PS5 paths and `src/gpu/**` semantics unchanged; shared writer changes only
  behind default-off options, with byte-identity tests.
- Success evidence must be visible: command output, PPM/window histogram,
  test counts — not claims.
- No separate PS4 renderer; GNM packets flow through the shared
  translate/lower/execute path.

## What is already proven (evidence)

- Real Terraria OrbShdr blobs found and parsed (`gcn_blob.zig`): VS
  `gcn-blob--3.bin` (exports POS0/PARAM0), PS `gcn-blob--4.bin` (exports MRT0).
  They decode and translate to 242/670 SPIR-V words with no unsupported
  instruction errors (`gcn-real-blob-report.md`).
- Real T#/S#/V# USER_DATA captured from Terraria's DCB (`gcn_resources.zig`),
  including PS T# `0x10168c8000` 1920×1080 RGBA8 matching `CB_COLOR0_BASE`
  (`bf5f030`).
- The PS texture is staged at binding 1 element 1, the exact slot the PS reads
  (`ebadf42`).
- The VS can rasterize a large triangle once its corner SSA values are kept
  out of the clobberable VGPR file (`bff98c0`); histogram showed 632,072
  `#FF4019` pixels.
- Hermetic fixture test of the real 790-dword DCB exists
  (`terraria_frame_test.zig`, 49/49 `test-ps4mode`).

## What is actually wrong today

1. **UV is constant.** The PS's VINTRP ops lower to no-ops; `fragment_inputs`
   are guessed (`allocated/enabled = 0b11`) rather than derived from the VS
   PARAM exports and GNM state. The PS samples texel (0,0).
2. **Position is synthetic.** `gl_Position` comes from a PS4-only corner
   override seeded from `VertexIndex`, not from the guest's real vertex
   fetch/transform. The rasterized primitive is one triangle, not the guest's
   intended quad.
3. **Resource selection is nondeterministic.** `gcn_resources.publish` is
   last-DCB-wins; captures have varied between the correct 1920×1080 texture
   and a 1024×4024 buffer, producing black frames in fresh runs.
4. **No correctness gate.** Nothing asserts that the first frame's pixels
   came from guest data, so regressions look like "black window".

## Approaches considered

1. **Full GCN correctness for all shaders.** Build complete VINTRP, vertex
   fetch, constant-buffer, detiling, sampler, and topology semantics. Highest
   fidelity, but 1–3k LOC and many game-run iterations before any frame is
   correct; not bounded to a first frame.
2. **First-frame reconstruction from captured guest data (chosen).** Fix only
   the path that produces the first frame: real vertex positions from the
   captured VS/V# data, real UV from VINTRP/PARAM, deterministic selection of
   the captured PS T#, correct topology/vertex count from the real draw
   packet. Delete the synthetic corner override and probe fallback from the
   final path. Bounded, verifiable, and it leaves a working seam for (1).
3. **Keep the current diagnostic frame.** No work, but explicitly an
   anti-goal (solid probe color), so rejected.

## Design (approach 2)

All new code lives in PS4-only modules or default-off shared options; PS5
native behavior is covered by existing byte-identity tests.

### A. Deterministic resource capture

Replace last-DCB-wins publishing with capture keyed by the program addresses
the first draw binds (the PS/VS values written to SH registers). The
captured T#/S#/V# set used for a draw must be the one published alongside
that shader pair. Add a test that feeds two DCBs with different resources and
asserts the right set is selected for each program pair.

### B. Real vertex path

- Remove the synthetic `vertex_corner_vgprs` / `vertex_position_corner_override`
  usage from the PS4 translator once real positions work (the options may
  remain default-off and unused for other bring-up cases).
- Feed the real VS through decoded GCN: buffer loads from captured V#/USER_DATA
  produce vertex positions; the existing `StorageBufferBinding` vertex-pull
  machinery in `rdna2.spirv` is the target shape.
- Decode the real draw packet's topology and vertex/index count instead of
  forcing three vertices. If the guest's vertex table cannot be recovered,
  the task stops and reports the exact missing register rather than
  substituting synthetic corners.

### C. Real UV path

- Decode VINTRP (`v_interp_p1/p2_f32`, attr index) and VS PARAM exports in
  `gcn_translate.zig`; derive `fragment_inputs.allocated/enabled` and the
  parameter mask from them instead of guessing.
- Assert in a unit test that the real PS's interpolated input traces back to
  the VS PARAM export, and that the PS SPIR-V no longer contains a constant
  `(0,0)` UV.

### D. Real texture path

- Use the deterministically selected PS T# (`gcn_resources`) and convert it
  with the existing `ps4_mode/image_layout.zig` detiling/format logic; stage
  it at the slot the translated PS reads.
- Sampler state comes from the captured S#; do not invent a checkerboard.
- Remove the synthetic 8×8 fallback if any before the final frame is claimed.

### E. Correctness gate and verification

- Extend `terraria_frame_test.zig` (or add a sibling PS4-only test) so it
  replays the captured first-frame DCB through capture → translate → draw
  state and asserts: real program pair selected, USER_DATA bindings present,
  VINTRP-derived fragment inputs, and a color target whose pixels are not a
  single constant. The test must fail on the current solid-color output.
- Live command (exact), with window screenshot and histogram:
  `PS5_PS4_MODE=on PS5_GNM_DIAG=1 timeout -s TERM 25 ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin`
- Success evidence: at least two distinct guest-sourced colors in the
  materialized target, a multi-colored window capture (not one flat color),
  and the same result on three consecutive runs.
- Full `zig build test` must remain green; PS5-gate tests unchanged.

## What is left to the builder

- Exact opcode/table fixes in `gcn_decode.zig` for whatever the real VS uses
  that the current subset mishandles.
- Precise `rdna2.spirv.Options` fields for fragment inputs / parameter mask
  once VINTRP and PARAM decoding are wired.
- Whether the guest's real vertex table is recoverable from captured V#
  descriptors; if not, report the blocker instead of substituting values.

## Risks

- The GCN translator's SOP1/SMRD/VOP rewrites are lossy; real semantics may
  need more than the listed fixes.
- No ground-truth PS4 screenshot is available in the repo, so "correct" is
  defined operationally as guest-sourced, multi-colored, and deterministic —
  not as pixel-identical to a console capture.
- Shared writer changes must stay default-off and byte-identical for PS5.
