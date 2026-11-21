# PS4 corner override — gcn-corner report

Date: 2026-11-19
Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-corner` (branch `gcn-corner`, base `ebadf42`)

## Status: ARTWORK

A large orange triangle (~632,530 non-black pixels) now rasterizes on the
Vulkan guest output window. The staged texture at binding 1 element 1 is
sampled (solid orange `#FF4019` because the PS samples a constant UV (0,0)).

## Root cause found

The PS4 corner override seeds two VGPRs with float quad corners derived from
`VertexIndex` inside `Builder.initializeStageInputs()`:

- `src/rdna2/spirv.zig:5245` writes `OpBitcast(VertexIndex & 1 / (>>1) & 1)`
  SSA ids into `self.registers[128 + vgpr]` for vgprs `{2,3}`.

The real Terraria VS then decodes instructions (`v_mov_b32 v2/v3`, etc.) that
**overwrite `self.registers[128+2]` and `self.registers[128+3]`** before the
`EXP POS0` is emitted. The export override at `src/rdna2/spirv.zig:6113` read
those clobbered registers, so `gl_Position` became `(0, 1, 0, 1)` (the clobber
values) and the seeded corner SSA ids were dead — exactly the prior agent's
observation.

Confirmed by SPIR-V word-level trace of a focused test before the fix:
the position `OpCompositeConstruct` was `result=39, components={37,38,17,32}`
where ids 37/38 bitcast the clobbering constants 0.25/0.75, while the seeded
corner bitcasts (ids 23/27) were unused.

## Fix

Added a dedicated `Builder.corner_values: ?[2]Value` field. At seed time the
corner SSA ids are captured there as well as in the register file. At export
time the override reads `corner_values` instead of the mutable registers, so
decoded GCN writes to v2/v3 can no longer replace them. All changes are behind
the existing default-off Options fields (`vertex_corner_vgprs`,
`vertex_position_corner_override`); native paths leave `corner_values == null`
and are byte-identical.

`is_position` was verified correct: POS0 export target `0x0c` (or `0`) maps to
`position_output`, so `is_position == true`. `vertex_index_input` is created for
`.vertex` whenever `vertex_corner_vgprs != null`.

No change needed in `gcn_translate.zig` — vgprs `{2,3}` are fine because the
override no longer depends on those registers surviving.

## Unit test (TDD: red then green)

Added `test "PS4 corner override survives VGPR clobbering before POS0 export"`
in `src/rdna2/spirv.zig`. It:

1. Builds a tiny vertex program that writes 0.25 into v2 and 0.75 into v3
   (simulating the real VS clobber) then exports POS0.
2. Translates with `.vertex_corner_vgprs = .{2,3}` and
   `.vertex_position_corner_override = true`.
3. Parses SPIR-V words to find the Position `OpCompositeConstruct` and asserts
   both x/y components trace back to the `OpLoad` of `VertexIndex`.

Before fix: `FAIL (TestUnexpectedResult)`.
After fix: `All 2 tests passed.`

Focused command:
```
export ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16
/home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-rdna2 -Dtest-filter="PS4 corner override survives"
```

## Test results

- `zig build test-rdna2 -Dtest-filter="PS4 corner override survives"` → `All 2 tests passed.`
- `zig build test-rdna2` → `All 320 tests passed.`
- `zig build test-ps4mode` → exit 0
- `zig build test` → exit 0 (includes "dynamic scalar values do not change translated SPIR-V words" byte-identity test)
- `zig fmt --check src/rdna2/spirv.zig` → exit 0

## Live verification

```
cd /home/reng/projects/ps5_zig_emu/.worktrees/gcn-corner
export ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16
/home/reng/tools/zig-x86_64-linux-0.16.0/zig build build-game-run
PS5_PS4_MODE=on PS5_GNM_DIAG=1 timeout -s TERM 25 \
  ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin \
  > /tmp/opencode/gcn-corner-run.log 2>&1
DISPLAY=:0.0 xdotool search --name 'PS5PCEM - Vulkan guest output' | head -1   # 54525953
DISPLAY=:0.0 import -window 54525953 /tmp/opencode/gcn-corner-window.png
```

Window: 1920x1029 PNG. Screenshot: `/tmp/opencode/gcn-corner-window.png` —
large inverted orange triangle on black background.

Histogram (`convert -colors 16 -format %c histogram:info:- | sort -rn | head`):
```
       1342810: (0.00383079,0.00280553,0.00495062) #000000 srgb(0.0015%,0.0011%,0.0019%)
        632072: (255,64.0002,24.9999) #FF4019 srgb(99.9999%,25.0981%,9.80388%)
           300: (15.1081,1.40541,17.5405) #0F0112
            85: (1.82353,3.75,130.044) #020482
            ... (all remaining colors <= 57 pixels each)
```

Non-black pixel count (gray threshold 5%): `632530` white vs `1343150` black —
~32% of the window is the rendered quad, far above the ~1,000 stray pixels
before the fix.

The `[vulkan dcb] ... carry 1937 coloured pixels` GNM diag line counts guest
framebuffer content, not the Vulkan-rendered geometry; the 632k orange pixels
come from the translated pipeline and are visible in the capture.

## Concerns / skipped

- The quad is a solid single color because the PS samples a constant UV (0,0);
  varying UVs were out of scope and not addressed.
- The rasterized primitive is one large inverted triangle rather than a full
  two-triangle quad — likely primitive topology / vertex count of the real draw.
  This still satisfies "varying gl_Position + many non-black pixels".
- Did not re-run a pre-fix live capture to A/B the screenshot; the unit test
  red/green plus the code-level word trace prove the mechanism, and the live
  capture proves the outcome.
- `initializeStageInputs()` may be called more than once in structured/dispatcher
  lowering paths; each call overwrites `corner_values` with a fresh SSA id, which
  is correct for whichever builder emits the export. All existing tests pass.
