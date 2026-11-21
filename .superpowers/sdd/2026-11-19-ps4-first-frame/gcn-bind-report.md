# gcn-bind report — 2026-11-19

Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-bind` (branch `gcn-bind`, base `66895ba`).

## Status: BLOCKED

The captured GCN resources are now published at the GNM submit boundary, but
wiring T#/S#/V# into the descriptor set **cannot produce artwork** with the
currently registered shader pair: the GCN→SPIR-V translation lowers the
SGPR-backed vertex position and texture UVs to immediate constants, so the VS
exports a single constant position (all triangles degenerate → no fragments)
and the PS samples one constant texel. This is upstream of resource binding.

## Exact live output

Build:
```
cd .../gcn-bind && ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
  /home/reng/tools/zig-x86_64-linux-0.16.0/zig build build-game-run
BUILD_OK
```
Run (`PS5_PS4_MODE=on PS5_GNM_DIAG=1 timeout -s TERM 25 ./zig-out/bin/game-run ...`):
```
[vulkan dcb] first graphics draw: compiling pipeline vs_words=169 ps_words=439
[gpu shaders] flip=1 pso_hit=1 pso_miss=1/0ms ... probe_ms=0
```
No `F4019` probe pixels, no errors/panics. Window captured with
`import -window <new-wid>` (new window detected by diffing `xdotool search`
IDs, because the parent session's stale probe window shares the same title).

## Pixel histogram (exact, final build, 1920x1029 guest window)

```
       1974608: (0.00340924,0.00282239,0.00460726) #000000 srgb(...)  <- near-black
           378: (13.6557,1.77049,19.1311) #0E0213
           100: (1.73,3.75,129.87) #020482
            83: (246.675,7.3012,6.56627) #F70707
            76: (115.25,12.6029,134.265) #730D86
            65: (89.5172,106.172,103.603) #5A6A68
            58: (7.17241,3.56897,253.138) #0704FD
            41: (58.3864,218.932,12.7045) #3ADB0D
            40: (18.8182,218.152,196.515) #13DAC5
            30: (215.613,78.8387,23.8065) #D84F18
```
≈1072 stray non-black pixels (same order as the ~1,913 baseline). No artwork.
Baseline before changes was identical (≈1,974,611 black), confirming the
capture wiring is behavior-neutral.

## Root cause (precise, with evidence)

Dumped the actual translated shader at runtime (`spirv-dis`):

Vertex (`rt_vs.spv`, 169 words):
```
%26 = OpCompositeConstruct %v4float %float_0 %float_0 %float_0 %float_1
OpStore %gl_Position %26          ; constant (0,0,0,1) for EVERY vertex
%31 = OpCompositeConstruct %v4float %float_1 %float_1 %float_1 %float_1
OpStore %12 %31                   ; constant color
```
All vertices land at NDC (0,0); triangles are degenerate → no fragments.

Pixel (`rt_ps.spv`, 439 words):
```
OpDecorate %26 Binding 1          ; sampled-image array at binding 1
%49 = OpCompositeConstruct %v2float %48 %50   ; both operands = 0.0
%53 = OpLoad %22 %52              ; %52 = AccessChain %26 [1]
%54 = OpImageSampleImplicitLod %v4float %53 %49   ; constant UV (0,0)
... OpSelect ... OpStore %14 %79  ; output = UnpackHalf2x16(texel.rg)
```
Even with a texture bound, the PS can only ever read texel (0,0).

Cause: `src/ps4_mode/gcn_translate.zig:buildOptions` never sets
`options.dynamic_scalar_binding`. The shared `rdna2` writer therefore lowers
every SGPR source (vertex attributes, UVs, USER_DATA resource indices) to an
immediate constant (0). The translated GCN VS originally did
`V_MOV v0..v3, s10/s11/...`; those SGPR values are lost.

## What was implemented (PS4-gated, clean)

- `src/ps4_mode/gcn_resources.zig`: `publish()` / `captured()` / `resetCapture()`
  — mutex-protected value copy of the decoded `Resources` (no allocator).
- `src/hle/libs/gnm_compat.zig`: at `sceGnmSubmitAndFlipCommandBuffers`, call
  `gcn_resources.publish(gcn_resources.capture(slice))` on the raw DCB. PS4 HLE
  boundary only; shared executor / register checks untouched.
- `src/vulkan/backend.zig`: extended the existing PS5-gate unit test to assert
  that captured resources never pull a PS5 draw into the fallback.
- No PS5/shared code path changed; no build.zig change needed.

## Verification

- `zig build test-ps4mode`: pass.
- `zig build test`: exit 0 (one earlier transient "failed command" on first run;
  clean rerun passed). The 49/49 ps4mode tests include the new publish/capture
  test.
- Live: no probe, no errors, frame unchanged near-black.

## Concerns / path forward

1. **Blocker to fix first**: make the translator emit a `dynamic_scalar_binding`
   and map GCN SGPR sources (vertex attrs, UVs, resource indices) to dynamic
   scalar indices instead of constants. Until the VS produces non-degenerate
   positions and the PS computes real UVs, no descriptor binding can show art.
2. Then: in `drawPs4FixedColor`, feed the captured USER_DATA rows via
   `writeGraphicsScalarValues`, stage the captured PS T#
   (0x10_168c8000, 1920x1080 RGBA8, display tiling) as a combined image sampler
   at binding 1 **array element 1** (the translator's `descriptor_index = 1`),
   via `stageSampledImage` + `updateSampledImageDescriptors`.
3. `publish` runs per submitted DCB; last DCB wins. The resource-bearing DCB is
   present in Terraria's stream (proven by the real-fixture capture test).
4. Copying `Resources` (~few KB) per submit under a mutex is negligible, but a
   latched "first valid T#" policy may be preferable if later DCBs clear it.
