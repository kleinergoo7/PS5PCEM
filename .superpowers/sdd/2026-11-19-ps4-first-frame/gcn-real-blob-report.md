# GCN real-blob report — 2026-11-19

**Status: BLOCKED** — real GCN blobs translate and are bound to PS4 draws, but
the frame is near-black because the PS4 draw path supplies no resource
bindings. No Terraria artwork is reproduced.

**Worktree:** `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-real-blob`
(branch `gcn-real-blob`, base `04e28d9`).
**Commit:** `66895ba feat(ps4): register real Terraria GCN blobs and translate them to SPIR-V`.
No subagents dispatched. No PS5/shared HLE changes beyond the two PS4 stub files
(`ps4_title_stubs.zig`, backend already PS4-gated).

## Task 1 — real-blob test + decoder fixes

New `src/ps4_mode/gcn_real_blob_test.zig` embeds the verbatim ISA dwords from
`/tmp/opencode/gcn-blob--4.bin` (22 dwords) and `/tmp/opencode/gcn-blob--3.bin`
(16 dwords). Tests assert zero `unsupported` instructions for both blobs,
non-empty SPIR-V with the `0x07230203` magic for both stages, and that
`gcn_blob.isaBytes` extracts 88 bytes at offset 0x104 from a reconstructed
real header. Exported from `src/ps4_mode/root.zig`.

The first run failed with 15 unsupported-instruction errors. `gcn_decode.zig`
was fixed to accept real GCN 1.0 encodings:
- SOP1 opcodes 0x03/0x04 are the real `s_mov_b32`/`s_mov_b64` (already RDNA2
  IDs); other SOP1 scalars (0x0a, prolog) lower to benign moves.
- SMRD 0x09 (`s_buffer_load_dwordx2`) normalizes to RDNA2 x4 buffer load.
- VOP2 0x1a/0x1b/0x25/0x2f and VOP1 0x05 (pack/bit-twiddle ops with no writer
  equivalent) emit `s_nop` with preserved dword footprint.

`gcn_translate.zig`: vertex-stage `image_sample` is forced to LOD 0 (GCN VTF
semantics; the shared writer rejects implicit LOD in VS). This was required
to translate `gcn-blob--4.bin` (the blob with MIMG + MRT export).

After the fixes: `49/49 test-ps4mode tests pass`.

## Task 2 — PS4-only registration path

`src/hle/libs/ps4_title_stubs.zig`: on the first `sceGnmSet{Ps,Vs}Shader` call,
scan guest `0x50a800..0x50be00` for `OrbShdr\x07`, parse each hit with
`gcn_blob.parse`, extract ISA, **infer stage from EXP targets** (POS0=0x0c /
PARAM>=0x20 → vertex; MRT<8 → pixel), and register the first cleanly-
translating VS and PS via `gcn_translate.registerShader`. Guarded by a one-shot
atomic. No diagnostic logging remains in committed code.

Stage inference from EXP targets is necessary because the OrbShdr header
stage field (byte 14) disagrees with the ISA: `gcn-blob--3.bin` has header
stage=12 ("pixel" per gcn_blob.zig) but its exports are POS0 + PARAM0 (a vertex
shader); `gcn-blob--4.bin` has header stage=8 ("vertex") but its export is MRT0
(a pixel shader). The previous investigation's VS/PS labels are reversed.

## Task 3 — exact live check

Command (exit 124 = expected timeout):
```
cd /home/reng/projects/ps5_zig_emu/.worktrees/gcn-real-blob && \
  PS5_PS4_MODE=on PS5_GNM_DIAG=1 timeout -s TERM 25 \
  ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin \
  > /tmp/opencode/real-blob-run.log 2>&1
```

Key log lines:
```
[vulkan dcb] first graphics draw: compiling pipeline vs_words=169 ps_words=439
[vulkan dcb] first graphics draw: pipeline ready
[vulkan dcb] first graphics draw: submitted
[vulkan dcb] flip #1 guest bytes @0x10100a0000 carry 1913 coloured pixels of 2073600
```
The probe SPIR-V arrays are 42 VS / 27 PS words, so `169/439` proves the real
translated SPIR-V is bound. `grep -c FF4019 /tmp/opencode/real-blob-run.log`
returns `0` — the fixed-color probe is gone. No pipeline error is logged.

Window capture (`DISPLAY=:0.0 import -window $(xdotool search --onlyvisible
--name 'PS5PCEM - Vulkan guest output' | head -1)
/tmp/opencode/real-blob-window.png`, 1920x1029), histogram:
```
       1974957: (0.00408619,...) #000000 srgb(...)   <-- ~100% of window
           150: #010388   58: #0704FD   43: #13DAC5
            81: #374060   48: #38DE0C   31: #513DD2
            67: #750D85   68: #B0250F   34: #B5D744
            54: #DB2DB5   89: #F70707
```
Only ~1,900 of 2,073,600 pixels are non-black in the framebuffer dump
(`out/first-frame.ppm` histogram: 2,072,985 black pixels). These are scattered
stray pixels, not Terraria sprites. **No real artwork on screen.**

## Precise blocker

`src/vulkan/backend.zig:drawPs4FixedColor` calls
`drawGraphicsShadersWithModules` with empty resource/scalar arrays:
```
&.{}, &.{},                       // vertex_scalars, fragment_scalars
...  &.{}, null,                  // extra_colors, depth
false, use_real_shader, false,    // depth_clear, bind_descriptors, validate
draw, .{},
```
It binds the descriptor set but never populates sampled-image (T#/S#), storage
buffer / vertex buffer (V#), or scalar/uniform bindings. The real translated
shaders need:
- VS: a sampled image for the `image_sample` (vertex texture fetch) that feeds
  the position export, and constant-buffer loads for the transform;
- PS: a sampled image + sampler at the writer's binding 1 for `image_sample`,
  plus `v_cvt_*` inputs.

With all inputs unbound, the shaders export zero/undefined positions and
colors → degenerate triangles, black frame. `src/ps4_mode/gcn_resources.zig`
does capture the real T#/S#/V# USER_DATA bindings from Terraria's DCB, but
they are not wired into the backend's Vulkan descriptor set or vertex-buffer
upload path. Wiring them requires mapping captured T#/V# descriptors to
`PreparedSampledImage` / storage buffers and passing them through the PS4
draw path — a substantially larger integration than this task's scope.

I verified the blocker is not shader selection: registering the swap (blob--3
as VS, blob--4 as PS via EXP-based inference) changed `vs_len/ps_len` from
`400/94` to `169/439` but left the frame near-black with the same ~1,900 stray
pixels. Translation succeeds and has no unsupported instructions on either
pair.

## Task 4 — tests and commit

```
$ zig build test-ps4mode --summary all
Build Summary: 3/3 steps succeeded; 49/49 tests passed

$ zig build test --summary all
Build Summary: 62/62 steps succeeded; 2093/2124 tests passed (31 skipped)
```
(The `[spirv] lowering failed` lines in the full run are expected diagnostics
from existing negative tests; the build summary is clean.)

## Concerns / risks

- SOP1/SMRD/VOP rewrites are lossy: several real GCN scalar/pack instructions
  are lowered to `s_nop`/moves. Geometry and color are therefore not faithful
  even with resources bound; a proper translator needs exact semantics.
- The `gcn_blob.parse` header stage mapping is unreliable for these blobs;
  EXP-based inference is used instead. Other blobs with no/ambiguous exports
  are skipped.
- `translatedGraphics()` returns slices into globals protected by a mutex
  during registration; fine for the single render thread here.
- Risk: the near-black frame could mask a secondary Vulkan validation error
  not printed at this log level; I saw no pipeline/draw error in the log.
