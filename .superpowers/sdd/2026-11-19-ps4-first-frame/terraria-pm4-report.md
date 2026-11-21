# Terraria PM4 wall — terraria-pm4 subagent report (2026-11-19)

**Status: BLOCKED** — the PS4 PM4 wall named in the brief is removed (no more
`RegisterOutOfRange`, no stopped queue, and the genuine draws hidden behind it
now execute), but `out/first-frame.ppm` is still not produced. The remaining
gap is a GCN→RDNA2 **render-target register-map** mismatch in the shared state
decoder, not an opcode/offset acceptance problem and not an absent draw.

Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/terraria-pm4` (branch
`terraria-pm4`). No file under `src/gpu/**` or any shared renderer/executor was
modified.

## What was changed (PS4-only)

1. **New `src/ps4_mode/pm4_sanitize.zig`** — std-only PS4 PM4 re-emitter.
   - Drops direct `SET_*_REG` packets whose offset range exceeds the shared
     register file (config 0xc00, context 0x400, shader 0x300, uconfig 0x4000).
     Why: the shared executor rejects the first such write with
     `RegisterOutOfRange` and stops the whole graphics queue.
   - Re-synchronises after a dropped packet by advancing **one word**, not the
     whole body. Why: in the captured GCN stream the "body" of the offending
     packet starts with the next real Type-3 header (word 13/14); skipping the
     body would discard every draw behind it.
   - Emits only recognised Type-3 opcodes with a body that fits; skips bare
     data/reserved/truncated words instead of forwarding them. Nothing is
     invented, and the shared register-range check is untouched.
   - Three unit tests with real dwords from the captured DCB, including the
     `context[0x10900]` write and the DRAW_INDEX_AUTO recovered behind it.
2. **`src/ps4_mode/root.zig`** — exports the new module and includes it in the
   `test-ps4mode` test root.
3. **`src/hle/libs/gnm_compat.zig`** — sanitises each decoded PS4 DCB into a
   temporary buffer before `agc_submit.submitDeviceStream`, and delivers the
   VideoOut flip completion the PS4 GNM driver owns (the guest registers a flip
   event and waits on it immediately after `SubmitAndFlipCommandBuffers`;
   the setup DCB has no FLIP/RELEASE_MEM packet for the shared path to publish).

## Evidence: PM4 wall removed

Baseline (commit `44fe782`, reproduced in this worktree):

```
[dcb] 0x100000034c 790 dwords
  00000: ACQUIRE_MEM 6 dwords
  00007: SET_CONTEXT_REG context[0xa205] x1
  00010: SET_CONTEXT_REG context[0xa2df] x1
  00013: SET_CONTEXT_REG context[0x10900] x1
  00016: <Truncated at 0x10100a00, 774 words remain>
  packets 4, draws 0, dispatches 0
[dcb] trimmed trailing allocation data: 16/790 dwords @0x100000034c
[gpu executor] packet rejected depth=0 stream=0x0 word=13/16 header=0xc0016900
               op=SET_CONTEXT_REG: RegisterOutOfRange
[dcb] queue stopped: RegisterOutOfRange
```

After the change (`PS5_TRACE=dcb,sceGnmSubmit`):

```
[gnm submit] sanitized DCB 790->664 dwords (kept=157 cfg=0 ctx=1 sh=0 ucfg=0 skipped=126)
[dcb] 0x7efd2c76a000 664 dwords
  packets 157, draws 2, dispatches 1
[vulkan dcb] dispatch skipped: MissingComputeProgram groups=32640x1x1 ...
[gpu draw state #1] color 0/0 mask=0xff mode=1, depth=none
[gpu draw state #2] color 0/0 mask=0xff mode=1, depth=none
[dcb] soft-satisfied 1 WAIT_REG_MEM packets ...
[agc submit] dcb words=664 releases=0
[gnm submit] dcbs=1 submitted=1
```

No `RegisterOutOfRange`, no `queue stopped`, no panic. With the flip completion
delivered, the guest leaves its stall and submits DCBs in a continuous render
loop (≈70k `sceGnmSubmitAndFlipCommandBuffers` hits in a 20 s run).

## Correction to the prior agent's "zero draws" finding

The prior report concluded "no draw-bearing DCB". A full raw scan of all 790
captured dwords (saved to `/tmp/opencode/terraria-dcb.bin`, 3160 bytes) shows
that is **wrong** — the PM4 walker stopped at word 16 before reaching them:

```
raw type-3 opcode census (all 790 words):
  0x69 SET_CONTEXT_REG 120, 0x76 SET_SH_REG 13, 0x10 NOP 10,
  0x58 ACQUIRE_MEM 3, 0x50 DMA_DATA 3, 0x2a INDEX_TYPE 2,
  0x2d DRAW_INDEX_AUTO 2, 0x79 SET_UCONFIG_REG 2,
  0x15 DISPATCH_DIRECT 1, 0x3c WAIT_REG_MEM 1, 0x48 EVENT_WRITE_EOS 1
```

Genuine packets recovered by the re-emitter (word offsets in the original
790-word DCB):

```
word 296  DISPATCH_DIRECT   body [0x7f80, 1, 1, 1]
word 558  DRAW_INDEX_AUTO   body [4, 2]
word 721  DRAW_INDEX_AUTO   body [4, 2]
```

Proof the resync is correct: the PM4 packet at word 13 declares a two-word body
`[0xc0066900, 0x0318]`, but `0xc0066900` is itself the header of the real
`SET_CONTEXT_REG offset=0x318` packet at word 14. Dropping only the word-13
header and rescanning its body recovers word 14 and, continuing, the draws.

## Exact verification command and result

```
cd /home/reng/projects/ps5_zig_emu/.worktrees/terraria-pm4
PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 \
  timeout -s TERM 20 ./zig-out/bin/game-run \
  --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin
```

```
EXIT=124
PPM:            none (out/ has no *.ppm; also checked literal out\first-frame.ppm)
queue stopped:  0
panic:          0
sceGnmSubmitAndFlipCommandBuffers hits: 69879
```

The command proves the PM4 wall is gone (no queue stop, guest render loop
running) but also that no frame is produced. PPM path/size/pixel summary are
unavailable because the file does not exist.

## Proven blocker: shared render-target decoder needs registers GCN never writes

Every recovered draw reaches the backend as:

```
[gpu draw state #N] color 0/0 mask=0xff mode=1, depth=none
```

`src/gpu/resources.zig:922 decodeColorTarget()` requires context registers
`0x318+slot` (present), `0x390+slot` (base high), `0x31c+slot` (info, present),
`0x31d+slot` (attrib, present), `0x3b0+slot` and `0x3b8+slot`. A full census of
the 790-word DCB's direct register writes (83 distinct context registers) shows
only `0x318..0x31d` and `0x31f..0x322` are written; `0x390`, `0x3b0`, `0x3b8`
are **never written**, so `decodeColorTarget` returns null for every slot.
`src/vulkan/backend.zig:19660` only dumps `out/first-frame.ppm` when a materialised
target has `colored != 0`; with zero color targets that gate is never reached.

This is a GCN→RDNA2 register-map/reconstruction gap in the shared renderer. The
brief forbids editing shared GPU/renderer code and prefers conservative filtering
over invented mappings; synthesising fake CB_COLOR high/attrib registers would
be exactly such an invented mapping and would fabricate a frame, so it was not
done.

## Tests

- `zig build test-ps4mode` — PASS (25 tests, including the 3 new PM4 sanitizer tests).
- `zig build test` — PASS, exit 0 on the final tree. The build logs contain
  cosmetic `failed command:` lines for several noisy test binaries already
  present in this repo; running one of them directly reports `All 65 tests
  passed.` with exit 0, and the overall build exit code is 0.

## Commits (PS4-only)

- `542b940` — feat(ps4): sanitize GCN PM4 at the GNM submit boundary
  (new `ps4_mode/pm4_sanitize.zig` + tests, `ps4_mode/root.zig` export,
  `gnm_compat.zig` sanitisation wiring and GNM-owned flip completion)

## Concerns / what was not checked

- The flip completion is delivered on every successful submit; with continuous
  submits this drives a tight render loop. It is PS4 driver behaviour (the title
  waits for the event it registered), but it was not compared against a real PS4
  trace of Terraria's flip cadence.
- The recovered compute dispatch is skipped (`MissingComputeProgram`); no attempt
  was made to bind PS4 GCN shaders — that is a separate renderer-level gap.
- No GCN→RDNA2 register mapping was invented, per the brief. A real frame needs
  the shared state decoder to accept the GCN CB_COLOR layout (or a PS4-specific
  mapping of the missing high/attrib registers derived from a hardware capture),
  which is outside this subagent's permitted file scope.
