# gcn-dynscalar report — 2026-11-19

Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-dynscalar` (branch `gcn-dynscalar`, base `3985a56`).

Commits: `3a20d7e` (implementation), `cdf8227` (strengthened value-independence test).

## Status: BLOCKED

The real translated GCN VS now (a) loads its SGPRs dynamically from the host
scalar buffer instead of baking `OpConstant`, and (b) has a PS4-gated,
vertex-index-derived POS0 override so `gl_Position` genuinely varies across the
four vertices of a quad. The PS4 draw now feeds those scalars from captured GCN
USER_DATA plus a minimal sprite transform. **Artwork still does not appear**:
the frame remains ~1,039 stray non-black pixels out of 1,976,475, identical to
the `gcn-bind` baseline. The remaining blocker is precise and upstream of the
draw path — see "Blocker" below.

## What was implemented (all gated; PS5 paths unchanged)

1. `src/ps4_mode/gcn_translate.zig`
   - `buildScalarSlots` walks the decoded `rdna2.Program`, producing one slot per
     SMEM destination word (with `producer_pc`) plus one per other SGPR read.
     The order is deterministic and shared with the draw path via
     `gcn_translate.scalarSlots(stage)`.
   - `buildOptions` now sets `dynamic_scalar_binding = 34`
     (`2 + rdna2.spirv.maximum_storage_images`, the backend's dedicated binding),
     `value_base = 0` for VS / `8448` for PS (matching `writeGraphicsScalarValues`),
     `scalar_registers = slots`, and `specialized_scalar_prefix_end = maxInt`.
   - PS4-only sprite transform: `vertex_corner_vgprs = {2, 3}` and
     `vertex_position_corner_override = true` for VS. The real Terraria VS uses
     two uninitialised VGPRs (v2/v3, decoded as `V_MOV v0,v2` multipliers in its
     `V_MAC_F32`) as per-vertex inputs; seeding them with
     `(VertexIndex&1, (VertexIndex>>1)&1)` turns a 4-vertex draw into a quad.

2. `src/rdna2/spirv.zig` (two new `Options` fields, default-null/false — no
   native behaviour change): `vertex_corner_vgprs` seeds the two float corner
   VGPRs from `VertexIndex`; `vertex_position_corner_override` writes POS0
   directly as `vec4(cx, cy, 0, 1)`.

3. `src/vulkan/backend.zig`
   - `ps4GraphicsScalars(stage, storage)` builds the draw-time scalar array in
     the exact slot order from `gcn_translate.scalarSlots`, using captured
     USER_DATA for entry SGPRs, the captured VS V# words for the first SMEM
     group, and a UV-origin/step transform for the two buffer-load groups.
   - `drawPs4FixedColor` passes those arrays to `drawGraphicsShadersWithModules`
     instead of `&.{}`. The probe fallback still passes empty arrays.
   - New PS5-gate unit test added next to the existing one.

## Verification

- `zig build test-ps4mode`: **52/52 pass** (new tests assert dynamic
  `OpAccessChain`/`OpLoad` from binding 34, VertexIndex decoration, stable slot
  order, and value-independent SPIR-V).
- `zig build test`: **exit 0** (the "failed command" trace lines are expected
  negative-test diagnostics).
- `zig build build-game-run`: clean.
- Live (exact command from the brief), `PS5_PS4_MODE=on PS5_GNM_DIAG=1`, 25 s:
  ```
  [vulkan dcb] first graphics draw: compiling pipeline vs_words=242 ps_words=670
  [vulkan dcb] first graphics draw: pipeline ready
  [vulkan dcb] first graphics draw: submitted
  [gpu shaders] flip=1 pso_hit=1 pso_miss=1/0ms ... probe_ms=0
  ```
  No errors, no panics, no probe pixels. Exit 124 is the expected timeout.

### Exact live output (final build)

```
[vulkan dcb] first graphics draw: target ready bytes=8294400 initialized=false
[vulkan dcb] first graphics draw: initial target staged
[vulkan dcb] first graphics draw: compiling pipeline vs_words=242 ps_words=670
[vulkan dcb] first graphics draw: viewport=(0,0)1920x1080 scissor=(0,0)1920x1080 discard=0 colors=1 write=0xf blend=0 extras=0 topo=3 cull=0 front=1 depth=0 dfunc=0 bsrc=0/0 bdst=0/0 sten=0 sfunc=0 target=0x10100a0000
[vulkan dcb] first graphics draw: pipeline ready
[vulkan dcb] first graphics draw: submitted
```

### Exact histogram (1920x1029 guest window, `magick -colors 16`)

```
       1974561: (0.00358553,0.00282245,0.00478966) #000000
           382: (14.3871,2.1129,19.4355) #0E0213
           100: (1.73,3.75,129.87) #020482
            85: (246.871,7.12941,6.41176) #F70706
            83: (111.015,12.4706,134.265) #6F0C86
            74: (89.5424,104.983,102.492) #5A6966
            60: (8.4667,3.32026,3.83977) #0704FC
            48: (54.6863,221.392,12.6667) #37DD0C
            42: (17.7429,219.4,199.857) #13DAC5
```

≈1,039 stray non-black pixels (baseline ≈1,072). No artwork, no visible quad.

## Blocker (precise)

`gl_Position` is now non-degenerate in the translated VS, but the **PS is still
black**: the real PS output is `UnpackHalf2x16(texel.rg)` from a texture sample at
binding 1, descriptor array element 1. `drawPs4FixedColor` never stages any
sampled image, so that element is a null descriptor → `texel = 0` → output
`(0,0,0,0)`. A non-degenerate black quad on a black target is invisible, which
is exactly what the histogram shows.

Staging the captured PS T# (`0x10_168c8000`, 1920x1080 RGBA8, display tiling)
cannot be done as a contained PS4-only change: the native path
(`prepareGraphicsResources` → `stageSampledImage` →
`updateSampledImageDescriptors`, backend.zig:26740-26766 and :28900-29033)
requires a `gpu.ShaderAnalysis`, `gpu.ShaderBindings`, a guest memory `reader`,
and a resolved sampler descriptor from the PS5 resource tracker. None of those
objects exist on the PS4 fallback path. Likewise the VS's own VTF sample at
binding 1 needs a tiny 2x2 position table staged as a combined image sampler;
that would require creating a Vulkan image/view/sampler and uploading host data,
well beyond the "small PS4-only function" the brief permits.

Two follow-ups, in order:
1. Stage a host-built 2x2 RGBA16F quad-position texture at sampled-image
   binding 1 element 1 and feed it to the VS; remove the synthetic POS0 override
   so the real VTF path supplies positions.
2. Stage the captured PS T# at the same binding for the PS, and make the PS UV
   vary (its VINTRP ops are currently lowered to no-ops by `gcn_decode`, so UV
   is constant (0,0) even with a texture bound). A fragment-side `FragCoord/Extent`
   UV source or a fixed VINTRP decoder is required.

## Concerns

- The POS0 override is deliberately synthetic (quad corners from VertexIndex),
  not the real GCN VTF result. It is gated behind new default-off `Options`
  fields, so PS5/native translation is byte-for-byte unchanged.
- `specialized_scalar_prefix_end = maxInt` is fine for these tiny prologs but
  would need narrowing if a long PS4 shader with SMEM loads inside branches is
  ever translated.
- `ps4GraphicsScalars` hardcodes the three-SMEM-group shape of the one real VS
  under test; a different VS would need its slot-to-value mapping revisited.
- The V# words supplied to SMEM group 1 come from captured VS USER_DATA[8..12]
  (the 16-byte-stride V# at register 0x54); this is plausible but not proven to
  be the exact descriptor the shader dereferences.
