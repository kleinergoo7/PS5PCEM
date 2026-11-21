# gcn-stage-image report — 2026-11-19

Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-stage-image` (branch `gcn-stage-image`, base `cdf8227`).
Status: **BLOCKED** — the sampled image is staged and written to the exact slot the PS reads, but no quad is rasterized, so the frame stays ~99.9% black. The blocker is upstream of texture staging (degenerate VS output), not a null descriptor.

## What was implemented

`src/vulkan/backend.zig` (all new code is PS4-gated):

1. `Renderer.ps4SampledImageDescriptor()` — pure, gated by `ps4_compat_enabled`. Reads the settled PS T# published by `ps4_mode.gcn_resources.captured()` and converts the GCN T# into the minimal RDNA2 `gpu.ImageDescriptor` the shared `stageSampledImage` path consumes: address `0x10_168c8000`, 1920x1080, unified format 56 (RGBA8), `dst_select = {4,5,6,7}`, `image_type = .color_2d`, pitch/tiling carried over from the captured T#. GCN tiling is mapped to the nearest RDNA2 family (`thin_1d -> standard_256b`, `thick_1d -> standard_4kb`, display -> linear).

2. `Renderer.stagePs4GraphicsSampledImage()` — PS4-gated. Builds a default sampler (`decodeSamplerDescriptor(&.{0,0,0,0})`), calls the existing `stageSampledImage(descriptor, sampler, 1, .two_d, null)`, then writes the resulting view/sampler into the real descriptor set (`self.descriptor_set`, chosen by `beginFrameDraw`) at **binding 1 (`sampled_image_2d_descriptor_binding`), array element 1** via `vkUpdateDescriptorSets`, mirroring `updateSampledImageDescriptors`.

3. `Renderer.releasePs4GraphicsSampledImage()` — releases view/sampler/image/storage-cache/render-target pins using the same rules as `GraphicsResources.deinit`.

4. `drawPs4FixedColor()` — when `use_real_shader`, stages + binds after `beginFrameDraw` and before `drawGraphicsShadersWithModules`, with a `defer` release after the draw is queued.

No shared register checks were relaxed; PS5/native paths are untouched.

## Verification (exact live output)

Build:
```
cd <worktree> && export ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16
/home/reng/tools/zig-x86_64-linux-0.16.0/zig build build-game-run     # OK
```

Run (`PS5_PS4_MODE=on PS5_GNM_DIAG=1 timeout -s TERM 25 ... > /tmp/opencode/gcn-stage-final.log`):
```
2084:[ps4] sampled image @0x10168c8000 1920x1080 -> binding 1 element 1
2093:[ps4] sampled image @0x10168c8000 1920x1080 -> binding 1 element 1
2138:[ps4] sampled image @0x10168c8000 1920x1080 -> binding 1 element 1
2139:[ps4] sampled image @0x10168c8000 1920x1080 -> binding 1 element 1
...
[vulkan dcb] first graphics draw: compiling pipeline vs_words=242 ps_words=670
[vulkan dcb] first graphics draw: submitted
```
The descriptor write lands in the same set that `drawPersistentGraphicsShaders` binds (`self.compute_pipeline_layout`, set 0), and `flushStorageDescriptors` only touches binding 0, so nothing overwrites it before the draw.

Window capture (`/tmp/opencode/gcn-stage-final.png`, ImageMagick 16-colour histogram):
```
       1974565: #000000 srgb(0.001375%,0.001107%,0.001850%)
           403: #0E0213
           106: #020482
            83: #F70707
            79: #700C86
            68: #5A6A68
            58: #0704FD
            44: #39DC0C
            ...
```
~500–700 non-black pixels out of 2,073,600 (the same stray-pixel pattern as before staging). No visible quad, no artwork.

## Precise blocker (investigated, not guessed)

I disassembled the live translated PS and VS (`PS5_DUMP_GRAPHICS_SPIRV=1`, `spirv-dis`):

- PS (binding 1, element 1): `OpAccessChain %uint_1` -> `OpImageSampleImplicitLod` -> `OpBitcast %uint(texel.r/g)` -> `UnpackHalf2x16`. UV is hardwired to (0,0) by a `V_MUL_F32` with literal 0 in the guest PS. So only texel (0,0) is ever sampled. The captured 684x480 sprite's texel (0,0) reads `(0,0,0,255)` from guest memory; the 1920x1080 colour target's texel (0,0) is all-zero before rasterization. Either way the PS output is black.
- I staged an 8x8 linear RGBA diagnostic checkerboard (red/blue, non-black at (0,0)) at the same binding/element and forced the PS's dynamic "kill" scalar non-zero — the frame stayed black. That rules out the descriptor and the sampler as the cause.
- VS (242 SPIR-V words): `gl_Position = vec4(0, 1, 0, 1)` is constructed from constants; the `gl_VertexIndex`-derived corners (`index&1`, `index>>1`) are computed but **unused**. Every vertex lands at the same clip position, so the triangle/quad is degenerate and virtually no fragments are rasterized. The live VS blob has no dynamic-scalar storage-buffer binding (`slots.len == 0`), so its SGPR values are baked as constants at translation time and overwrite the seeded `vertex_corner_vgprs` values before the position export.

Conclusion: the null-descriptor half of the task is fixed and verified at the API level. Real artwork cannot be shown until the VS position export actually uses the vertex-index corners (i.e. the `vertex_position_corner_override` path must preserve the seeded VGPR2/3 instead of letting later guest instructions replace them) — that is a shader-writer change, outside the texture-staging scope and explicitly not attempted here.

## Tests

- `zig build test-ps4mode` — exit 0.
- `zig build test` — exit 0. Added `PS4 sampled-image staging is gated off for PS5 draws`: with `ps4_compat_enabled=false` the descriptor helper returns null; with `true` it returns the settled PS T# view. (This Zig build prints a pre-existing `failed command:` line from a GPU-dependent test binary on both base `cdf8227` and this branch; exit status is 0 in both cases.)

## Concerns / skipped

- `shortcut: GCN tiling is approximated by the nearest RDNA2 family, upgrade when PS4 microtile detiling is implemented`. Thin-1D guest bytes are present (`raw_probe_nz=164`) but detiling yields black; correctness of the view depends on a proper PS4 tiling decode.
- Did not change the shader writer or force vertex-index corners — that is the actual blocker and a separate, shared-path change.
- The diagnostic checkerboard used during investigation was removed from the final diff; it proves nothing visually while the VS is degenerate.

## Commit

`ebadf42 feat(ps4): stage captured PS sampled image at binding 1 element 1` on branch `gcn-stage-image`. Working tree clean.
