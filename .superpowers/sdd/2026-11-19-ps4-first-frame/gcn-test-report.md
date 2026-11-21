# GCN focused-test report — 2026-11-19

## Status
DONE. Two new PS4-only tests in `src/ps4_mode/terraria_frame_test.zig`,
wired into `test-ps4mode` via `src/ps4_mode/root.zig`. Committed on branch
`gcn-test` (worktree `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-test`,
base `3dadccb`). No PS5 code and no `src/gpu/**` touched; no shared HLE
implementation changed.

## Exact test command + output

```
$ cd /home/reng/projects/ps5_zig_emu/.worktrees/gcn-test
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode --summary all

Build Summary: 3/3 steps succeeded; 33/33 tests passed
test-ps4mode success
+- run test 33 pass (33 total) 3ms MaxRSS:5M
   +- compile test ReleaseSafe native-native cached 10ms MaxRSS:41M
```

Individual-test confirmation (direct `zig test`, same module graph):

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig test src/ps4_mode/terraria_frame_test.zig
1/19 terraria_frame_test.test.Terraria DCB: guest colour target, draws and shader programs survive the PS4 path...OK
2/19 terraria_frame_test.test.NEGATIVE (missing capability): GCN shader words are not translated to SPIR-V; PS4 replay uses the probe fallback...OK
...
All 19 tests passed.
```

The 33 total = previous 31 baseline + 2 new tests. PASS, 0 failures.

## Commits
One commit on `gcn-test` (see `git log -1` in the worktree for the exact hash),
message: `test(ps4): drive first-frame graphics path from captured Terraria DCB`.

## What the test proves

The positive test feeds the **exact 790-dword / 3160-byte embedded fixture**
(generated verbatim from `/tmp/opencode/terraria-dcb.bin`, embedded as a Zig
literal so the test is hermetic — no file read, no game run, no guest memory,
no GPU backend) through the same four-call PS4 path used by
`sceGnmSubmitAndFlipCommandBuffers` in `src/hle/libs/gnm_compat.zig`:

1. `colorTargetAddress` — recovers the guest CB base the game writes at
   word 14 (`CB_COLOR0_BASE = 0x10100a00` -> guest address `0x0010_100a_0000`).
2. `synthesizeRenderTargetRegs` — produces the 9 expected dwords
   (BASE_HIGH/DIM/DEPTH for the one CB slot), with the decoded VideoOut dims.
3. `synthesizeShaderProgramRegs` — injects the PS (`0x008`) and VS (`0x048`)
   SH program-address registers from `sceGnmSet{Ps,Vs}Shader` state, asserting
   the exact low/high split of both addresses.
4. `sanitize` — keeps 157 real packets and drops 1 out-of-range context
   write, yielding 664 dwords. The walk over the recovered stream asserts
   it retains the game's real work: **one `DISPATCH_DIRECT`**
   (body `0x7f80,1,1,1`) and **both `DRAW_INDEX_AUTO`** packets
   (each `count=4, index_offset=2`), all with intact bodies.

This means future rendering work can be driven by a deterministic test that
asserts what the *game* actually supplies, instead of requiring a full game
run.

## Task 2 — NEGATIVE capability marker (choice and why)

**Chosen: assert the current fallback (GREEN), with a commented-out RED
assertion and a `shortcut:` annotation. I did NOT encode the desired behavior
as a failing test.**

Why: encoding `guest GCN shader words are translated into real SPIR-V and
bound` as a live RED test requires an API that does not exist anywhere in the
PS4 modules — there is no GCN->SPIR-V translator entry point to call, so such
a test could not compile cleanly. The task explicitly permits the alternative:
assert the current fallback and annotate with `shortcut:` plus what must be
replaced. The test documents that the PS4 path records only
`sceGnmSet{Ps,Vs}Shader` addresses and injects SH program-address registers;
the shared backend cannot consume GCN ISA, so `src/vulkan/backend.zig`
(`drawPs4FixedColor`) replays the fixed-color probe shader. The `shortcut:`
comment states the replacement: a real GCN->SPIR-V translator bound at the
PS4 submit boundary, after which the RED assertion
(`n > max_shader_reg_dwords`) should be uncommented.

## Concerns / skipped
- The NEGATIVE test is GREEN, not RED: it records the missing capability
  rather than failing on it, because no translator API exists to compile
  against. When a translator is added, enable the commented assertion.
- The full `zig build` was also run to completion after the required test:
  `EXIT: 0` (cold build exceeded the 120s foreground timeout, so it was
  backgrounded and finished cleanly). Cross-target impact is therefore
  confirmed nil.
- The fixture is a single captured setup DCB; it does not cover gameplay
  frames with different CB slots or draw counts. Extending it needs a new
  capture.
