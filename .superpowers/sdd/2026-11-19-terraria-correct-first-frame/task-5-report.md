# Task 5 report — Select each draw's real PS texture

## Status
Complete. Implemented, tested (TDD), and committed. Working tree clean.

## Commit
`663a2db feat(ps4): bind each draw's own GCN texture resource`

Files (exactly the brief's list):
- `src/ps4_mode/gcn_translate.zig`
- `src/vulkan/backend.zig`
- `src/ps4_mode/gcn_real_blob_test.zig`

## What changed
- `gcn_translate.zig`: added `pub fn sampledImageUserIndexFor(program: ProgramPair) ?u8`.
  It decodes the registered PS ISA, finds the `image_sample`/`Mimg` instruction and
  returns its decoded resource SGPR (`tsgpr`, equivalently
  `SampledImageBinding.resource_sgpr`) as the USER_DATA word index, with a
  bounds check against `user_data_words`. Returns null without a registered PS
  or when that PS samples no image. Access is guarded by the existing registry
  mutex.
- `backend.zig`: `ps4SampledImageDescriptor` and `stagePs4GraphicsSampledImage`
  now take the bound `ProgramPair`; the former replaced the "last PS T#" loop
  with a lookup for `binding.user_data_index == sampledImageUserIndexFor(program)`
  on the per-draw resources. The detiling/format conversion is untouched and no
  fallback texture is staged — when nothing matches, the functions return null.
  `drawPs4FixedColor` passes the already-available `program`.
- Tests: added the brief's test in `gcn_real_blob_test.zig` (with the FIFO setup
  required by the decisions) and extended the backend gating test to assert that
  the first draw resolves to `0x10170c0000` and the second to `0x10168c8000`.

## TDD evidence
1. Wrote `PS image samples the USER_DATA slot of its own draw` first; `zig build
   test-ps4mode` failed to compile with `gcn_translate has no member named
   'sampledImageUserIndexFor'` (expected).
2. Implemented the function and backend lookup; `zig build test-ps4mode` passed.
3. Final verification: `zig build test-ps4mode` PASS, `zig build test-vulkan`
   exit 0, full `zig build test` exit 0.

## Concerns / notes
- The brief's test lines used `first.userData(.pixel)[index] << 8` directly.
  `userData` returns `[]const u32`, so the 40-bit address shifts out of `u32`
  (verified: yields `0x170c0000`, not `0x10170c0000`). I kept the exact expected
  values and added `@as(u64, ...)` casts so the test is valid Zig. No behavior
  was changed to accommodate it.
- No checkerboard/fallback texture staging existed in the PS4 image path to
  remove; `stagePs4GraphicsSampledImage` already returns null on a missing or
  unstageable descriptor, which is preserved.
- `sampledImageUserIndexFor` returns the first image sample's resource slot.
  Terraria's PS has exactly one; a future PS sampling multiple T#s would need a
  per-binding descriptor selection, which is out of scope here.
- Skipped: did not dispatch a review subagent (per instructions).

## Fix round 1

**Finding:** `sampledImageUserIndexFor` returned the raw decoded SGPR as a
USER_DATA index without subtracting the PS USER_DATA base (`0x0c`/12). It only
worked for Terraria because `Mimg` SRSRC field 1 -> `.tsgpr = 4` and the DCB
binds the T# at register `0x10` -> `user_data_index = 16 - 12 = 4`; the two index
spaces coincided.

**Ruling:** implement the subtraction (not merely reword the contract), keep the
change in the three Task 5 files, keep PS5/native unchanged, keep the two-draw
assertions passing, and add a focused test with an SGPR >= `0x0c` whose USER_DATA
index differs (e.g. raw SGPR `0x10` -> index 4).

### Changed files
- `src/ps4_mode/gcn_translate.zig` — added private
  `psUserIndexFromSgpr(sgpr: u32) ?u8`, which computes `sgpr - Stage.pixel.userDataBase()`
  with guards for `sgpr < base` and `index >= user_data_words`.
  `sampledImageUserIndexFor` now normalizes the decoded `Mimg.tsgpr` to an
  absolute GCN SGPR (Terraria's captured operand is USER_DATA-row-relative;
  already-absolute operands are used as-is) and converts it through that helper.
- `src/ps4_mode/gcn_real_blob_test.zig` — added
  `PS sampled-image slot subtracts the USER_DATA base from an absolute SGPR`,
  asserting SGPR `0x10` -> index 4 and SGPR `0x14` -> index 8 with synthetic
  MIMG operands. The existing two-draw test
  `PS image samples the USER_DATA slot of its own draw` is unchanged and still
  passes.
- `src/vulkan/backend.zig` — untouched in this round; it keeps consuming
  `sampledImageUserIndexFor(program)`.

### Test commands and output
```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode
ps4mode_exit=0                       # no output on success

$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig test -OReleaseSafe \
    -target native-native -mcpu x86_64_v3 --dep rdna2 \
    -Mroot=src/ps4_mode/root.zig -Mrdna2=src/rdna2/root.zig \
    --test-filter "PS sampled-image slot subtracts"
1/2 root.test_0...OK
2/2 gcn_real_blob_test.test.PS sampled-image slot subtracts the USER_DATA base from an absolute SGPR...OK
All 2 tests passed.

$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig test -OReleaseSafe \
    -target native-native -mcpu x86_64_v3 --dep rdna2 \
    -Mroot=src/ps4_mode/root.zig -Mrdna2=src/rdna2/root.zig \
    --test-filter "PS image samples the USER_DATA slot"
1/2 root.test_0...OK
2/2 gcn_real_blob_test.test.PS image samples the USER_DATA slot of its own draw...OK
All 2 tests passed.

$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test
full_exit=0
```

### Commit
`2d276c5 fix(ps4): subtract PS USER_DATA base from sampled-image SGPR`

### Notes
The normalization branch exists only to preserve Terraria's captured
row-relative operand; absolute GCN resource SGPRs now go through the exact
`SGPR - 0x0c` conversion the plan specifies. PS5/native paths are untouched.
