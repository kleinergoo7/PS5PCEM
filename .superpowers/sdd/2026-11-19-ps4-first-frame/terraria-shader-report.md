# Terraria first-frame attempt — `terraria-shader` worktree report

**Status: FRAME_RENDERED**

Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/terraria-shader`
Branch: `terraria-shader`
Base HEAD: `9306997`

## Verification command (exact)

```sh
cd /home/reng/projects/ps5_zig_emu/.worktrees/terraria-shader
PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 timeout -s TERM 30 \
  ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin
```

Exit 124 (the harness timeout; the title keeps running) with a captured frame.

## Frame

- Path: `out/first-frame.ppm`
- Size: 6,220,817 bytes (P6 header 17 bytes + 1920*1080*3)
- Dimensions: 1920x1080, maxval 255
- Pixel summary: 663,552 / 2,073,600 nonzero texels (32%); exactly two colors —
  `0,0,0` (1,410,048) and `255,64,25` (663,552), the existing fixed-color probe
  shader export `(1.0, 0.25, 0.1)`.
- Backend evidence (from the run):
  ```
  [ps4_mode] mode=ps4-gnm compat=active
  [vulkan dcb] render target cache: first @0x10168c8000 1920x1080
  [vulkan dcb] first graphics draw: target ready bytes=8294400 initialized=false
  [vulkan dcb] first graphics draw: initial target staged
  [vulkan dcb] first graphics draw: compiling pipeline vs_words=143 ps_words=74
  [vulkan dcb] first graphics draw: pipeline ready
  [vulkan dcb] first graphics draw: submitted
  [vulkan dcb] dumped out/first-frame.ppm (1920x1080)
  [vulkan dcb] first graphics draw: readback colored_pixels=663552 outcome=0
  ```
  (143/74 are the lengths of the fixed-color probe SPIR-V arrays, i.e. the PS4
  fallback path; the frame is written by the normal render-target
  materialization/readback path, not fabricated.)
- Shader-set imports recorded: `sceGnmSetVsShader` and `sceGnmSetPsShader`
  thousands of times in the diagnostic hit report.

## What changed (all console-specific)

1. `src/ps4_mode/shader_binding.zig` (new): PS4-only store for the guest shader
   pointers captured by the two GNM shader-set imports, with atomic access.
2. `src/hle/libs/ps4_title_stubs.zig`: the two NIDs (`bQVd5YzCal0`,
   `gAhCn6UiU4Y`) are no longer generic zero-return stubs; they are PS4-NID-keyed
   exports that record the pointer.
3. `src/ps4_mode/pm4_sanitize.zig`: `synthesizeShaderProgramRegs()` emits
   `SET_SH_REG` packets for PS (0x008/0x009) and VS (0x048/0x049) program
   addresses; zero programs emit nothing (PS5/native streams are untouched).
4. `src/hle/libs/gnm_compat.zig`: prepends those packets to each sanitized PS4
   DCB before handing it to the shared executor.
5. `src/vulkan/backend.zig` + `src/game_run.zig`: a PS4-gated flag and fallback
   that replays a bound VS/PS pair with the existing fixed-color probe shader
   into the guest's own decoded color target (GCN binaries are not consumed by
   the shared AGC decoder). Every use is behind `ps4_compat_enabled`, which is
   set only when PS4 compat is active.

## Tests

- `zig build test-ps4mode`: PASS (includes new shader-binding and PM4 synthesis
  tests, plus the "no recorded shader programs injects nothing" test).
- `zig build test`: PASS (includes "PS5 draws never take the PS4 fixed-color
  fallback", which sets both program registers and proves the fallback is
  disabled with the PS4 flag off and enabled only with it on).
- `zig fmt --check` clean on all touched files.

## Commits

- `1581cbb feat(ps4): bind GNM shaders and capture Terraria first frame` (on
  `terraria-shader`, based on `9306997`). Clean worktree after commit.

## Exact verification command output (final run)

```
EXIT=124
--- PPM ---
-rw-r--r--. 1 reng reng 6220817 19. Nov 06:37 out/first-frame.ppm
--- frame evidence ---
2082:[vulkan dcb] first graphics draw: target ready bytes=8294400 initialized=false
2083:[vulkan dcb] first graphics draw: initial target staged
2084:[vulkan dcb] first graphics draw: compiling pipeline vs_words=143 ps_words=74
2085:[vulkan dcb] first graphics draw: viewport=(0,0)1920x1080 scissor=(0,0)1920x1080 discard=0 colors=1 write=0xf blend=0 extras=0 topo=3 cull=0 front=1 depth=0 dfunc=0 bsrc=0/0 bdst=0/0 sten=0 sfunc=0
2086:[vulkan dcb] first graphics draw: pipeline ready
2087:[vulkan dcb] first graphics draw: submitted
2088:[vulkan dcb] dumped out/first-frame.ppm (1920x1080)
2089:[vulkan dcb] first graphics draw: readback colored_pixels=663552 outcome=0
5591:sceGnmSetVsShader 3522
5592:sceGnmSetPsShader 3522
...
```

Exit 124 is the `timeout -s TERM 30` harness limit; the frame is captured
~2 s into the run. With stdout unbuffered (`stdbuf -o0`) the startup line reads
`[ps4_mode] mode=ps4-gnm compat=active`.

## Concerns / not checked

- The first frame is the diagnostic fixed-color quad, not Terraria's real
  artwork; this is the authorized PS4 fallback because the GCN shader binary
  cannot be decoded by the shared AGC path.
- The synthesized 1920x1080 extent is the VideoOut output size, not necessarily
  Terraria's internal render resolution.
- The run is terminated by the 30 s harness timeout rather than exiting on its
  own; the frame is captured well before that.
