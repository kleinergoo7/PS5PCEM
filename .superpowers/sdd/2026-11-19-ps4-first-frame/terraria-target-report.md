# Terraria first-frame attempt — `terraria-target` worktree report

**Status: BLOCKED** — the originally reported blocker (every draw reaching the
backend as `color 0/0`) is **fixed** by PS4-boundary render-target register
synthesis, but a deeper, proven blocker remains: Terraria's shader-binding GNM
imports are no-op stubs, so no graphics shader program is ever bound, the
Vulkan backend never issues a guest graphics draw, and no render target is ever
materialized. No `out/first-frame.ppm` is produced.

Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/terraria-target`
Branch: `terraria-target`

## Verification command (exact, from task)

```sh
cd /home/reng/projects/ps5_zig_emu/.worktrees/terraria-target
PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 timeout -s TERM 30 \
  ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin
```

Result (exit 124 = harness timeout, as before):

```
BUILD_OK
RUN_EXIT=124
=== PPM CHECK ===
NO out/first-frame.ppm
NO literal-backslash file either
```

No PPM exists (neither `out/first-frame.ppm` nor the literal-backslash variant),
so there is no byte size or pixel summary to report.

## What was changed and verified

Commit `9306997 feat(ps4): synthesize missing GCN render-target registers at GNM submit`.
Files touched (PS4-only): `src/ps4_mode/pm4_sanitize.zig`,
`src/hle/libs/gnm_compat.zig`. No `src/gpu/**` or shared renderer file changed.
No PS5/native stream touched; the shared executor's register-range check still
applies.

At `sceGnmSubmitAndFlipCommandBuffers`, a `SET_CONTEXT_REG` prefix is prepended
to every sanitized DCB, for each colour slot whose CB base the guest actually
writes at `0x318 + i*15`:

| Register | Value | Derivation / why |
|---|---|---|
| `0x390+i` BASE_HIGH | `0` | PS4 GPU addresses are ≤40-bit; the guest's 32-bit BASE shifted `<<8` by the decoder already holds all meaningful bits, so bits 40..47 are zero. |
| `0x3b0+i` DIM | `((1920-1)<<14) | (1080-1)` | GCN keeps the extent in another register block; the known 1920x1080 VideoOut output gives a non-degenerate target (height bits 0..13, width bits 14..27). |
| `0x3b8+i` DEPTH/TILE | `0` | 1 slice (`depth = value+1`) and linear tiling, so the guest's PITCH applies directly and no CMASK/DCC metadata is needed. |

Unit tests added for the synthesis and the no-base case. Verification:

```
=== test-ps4mode ===
OK
=== full test ===
FULL_TEST_EXIT=0
```
(`zig build test-ps4mode`, `zig build test`, `zig fmt --check` all clean.)

### Direct evidence the stated blocker is fixed

With `PS5_TRACE=sceGnmSubmit` added only as a diagnostic (not part of the
successful verification command):

```
[gnm submit] sanitized DCB 790->673 dwords (rt-prefix=9 kept=157 cfg=0 ctx=1 sh=0 ucfg=0 skipped=126)
[gpu draw state #1] color 1/1 mask=0xff mode=1, depth=none
...
[gpu draw state #16] color 1/1 mask=0xff mode=1, depth=none
  rt0=0x10168c8000 1920x1080 fmt=10/0 sw=0 write=0xf
```

Before the change these lines were `color 0/0` with no `rt0=`, exactly as
reported. So `decodeRenderState` now sees the render target and the `colored !=
0` gate's prerequisite (`format = 10` ⇒ RGBA8, 4 bytes/texel) is in place.

## Proven blocker: shader program registers are never written

The PPM still cannot be produced because **no graphics shader program is ever
bound**, so the Vulkan backend returns before any draw reaches the render
target. Evidence chain:

1. The recovered DCB writes CB target registers at `0x318..0x31d` / `0x31f..0x322`
   and SH registers only at `0x10, 0x18, 0x4c, 0x4e, 0x54, 0x244, 0x248, 0x24c`
   (compute/user-data blocks). A scan of **all** submitted DCBs for
   `SET_SH_REG` writes at the graphics program bases `0x008` (PS), `0x048`
   (VS), `0x088` (GS), `0x0c8` (ES), `0x108` (HS) found **zero** writes.
2. `gpu.resources.ShaderStage.programAddress()` reads exactly those SH
   registers (`src/gpu/resources.zig:127-144`). With none written it returns
   `null`.
3. Instrumenting the Vulkan backend's `dcbDraw` showed for the first 20 draws:
   ```
   [diag dcbDraw] #0 opcode=0x2d vtx=false ps=null probe=true
   ... (identical for all 20)
   ```
   so `has_vertex = false`, `has_fragment = false`.
4. `dcbDraw` therefore takes the no-shader path; even with the graphics probe
   forced on (temporary `enable_graphics_probe = true`, since reverted) no
   `first graphics draw` checkpoint, no `[gpu materialize]`, and no PPM
   appeared — the probe draws to its own synthetic target, not the guest
   render target.
5. Root cause at the HLE boundary: Terraria's shader-binding imports are no-op
   stubs in `src/hle/libs/ps4_title_stubs.zig:82,85`:
   - `sceGnmSetPsShader` — NID `bQVd5YzCal0` → `return 0`
   - `sceGnmSetVsShader` — NID `gAhCn6UiU4Y` → `return 0`

   (NID names verified against `ps4libdoc`/`orbisLibGen` libSceGnmDriver tables.)
   The guest therefore never emits the `SET_SH_REG` packets that bind its GCN
   VS/PS programs, and the shared decoder has nothing to translate.

Implementing those imports (capture the `GnmVsShader`/`GnmPsShader` structures
passed by the guest, translate their stage-register blocks into `SET_SH_REG`
packets at the PS4 boundary) plus the associated GCN→RDNA2 shader translation
is a separate, substantially larger PS4/HLE task, outside the authorised
scope of "synthesize the missing render-target registers in
`pm4_sanitize.zig` / `gnm_compat.zig`". All temporary diagnostics used to
establish this evidence were removed; the committed tree is clean.

## Commits on `terraria-target`

1. `9306997` — `feat(ps4): synthesize missing GCN render-target registers at GNM submit`

(Based on `542b940` from the parent task.)

## Concerns / not checked

- No PPM, so no pixel summary (dimensions/uniformity) can be given. The
  synthesized 1920x1080 extent is the VideoOut output size, not necessarily
  Terraria's internal render resolution; if shader binding is later fixed, the
  DIM value may need refining against the guest's actual PITCH/viewport.
- The shader-set stubs are a measured wall for **all** Terraria graphics, not
  just the first frame. Until they are implemented (or GCN shader programs are
  otherwise bound), no guest draw can execute and no frame can be captured by
  this or any later frame-hunting step.
- Full `zig build test` exited 0; its "failed command" log lines are from tests
  that deliberately exercise failure paths, not test failures.
