# Task 3 report — Real UV from VINTRP and VS PARAM exports

Status: DONE

## What changed

- `src/ps4_mode/gcn_translate.zig`
  - Added `pub const FragmentInputs = struct { allocated: u32, enabled: u32 };` —
    the PS4-facing mask; bits are raw VS PARAM / VINTRP ATTR indices.
  - Added `fragmentInputsFromIsa(vertex_isa, pixel_isa)`: walks the registered
    VS's decoded `exp` instructions, mapping every `target >= 0x20` to bit
    `target - 0x20` in both `allocated` and `enabled`; then walks the paired
    PS's decoded `v_interp_p1_f32`/`v_interp_p2_f32` (`Vintrp.attr`) and returns
    null + a `Diagnostic` if any attr is not covered by the mask (never guesses
    an input). Decode errors also report null + diagnostic.
  - Added `pub fn fragmentInputsFor(program: ProgramPair) ?FragmentInputs`, the
    program-keyed lookup over the Task 2 registry (null when a stage is absent
    or attrs are unreconciled).
  - Threaded an optional `fragment_inputs` through `translateShaderSlots` →
    `buildOptions`. The registered pixel stage now uses the derived mask
    instead of the hardcoded `.{ .allocated = 0b11, .enabled = 0b11 }`. A
    standalone `translateShader` (no program pair) keeps the legacy default;
    on a registered mismatch the pixel stage declares zero inputs plus a
    diagnostic rather than reverting to the guessed mask.
  - Updated the two `buildOptions` callers in this file's existing tests.
- `src/ps4_mode/gcn_real_blob_test.zig`
  - Added the brief's test (plus a small `constantUvOnly` SPIR-V word scanner)
    and one anti-fabrication test for the null/diagnostic branch.
- `src/rdna2/spirv.zig`: **unchanged**. Its existing `FragmentInputs.allocated`
  and `.enabled` are `u16`, wide enough for the u32 PS4 mask after `@intCast`;
  no new field was needed, so the shared writer and PS5 byte identity are
  untouched.

## Test-data note (important)

The embedded arrays are named after the OrbShdr header stage field, but the
runtime classifies shaders by EXP target (`ps4_title_stubs.stageFromIsa`:
POS0 `0x0c` / PARAM `>= 0x20` → vertex, MRT `< 8` → pixel), which agrees with
the design spec ("VS ... exports POS0/PARAM0", "PS ... exports MRT0"). So:
`ps_words` (blob--3, `EXP 0x0c` + `EXP 0x20`) is the real **VS**, exporting
PARAM0 → mask bit 0; `vs_words` (blob--4, `EXP 0x00` + image sample) is the real
**PS**. The new test registers them by that runtime classification, not by the
misleading array names. `fragmentInputsFor` returns `{ allocated = 1, enabled =
1 }` for the real pair, satisfying Task 6's `allocated != 0` gate.

## TDD evidence

- Wrote the test first with `expected_param_mask_from_vs_exp = 1` (the one bit
  from the real VS's PARAM0 export) and the `!constantUvOnly(...)` assertion.
- `zig build test-ps4mode` failed to compile:
  `root source file struct 'gcn_translate' has no member named 'fragmentInputsFor'`.
- Implemented the helper, public API and option threading; the new test and all
  existing tests pass.

## Tests (Zig 0.16 at /home/reng/tools/zig-x86_64-linux-0.16.0/zig)

- `zig build test-ps4mode --summary all`: exit 0 —
  `3/3 steps succeeded; 57/57 tests passed` (was 55 before this task; +2 new).
- `zig build test --summary all`: exit 0 —
  `62/62 steps succeeded; 2104/2135 tests passed (31 skipped)` (was
  2102/2133 before this task). No test binary reported a failure; the
  `failed command:` lines are the same pre-existing harness noise documented
  in the Task 1/2 reports. No `rdna2` source changed, so all native/PS5
  byte-identity tests are unchanged and green.
- Global Zig cache: 107 MB, under the 5 GB cap.

## Commit

`b6f7e4c feat(ps4): derive PS fragment inputs from GCN VINTRP and VS PARAM exports`
(only the brief's two modified files; `src/rdna2/spirv.zig` needed no edit).

## Concerns / not checked

- **The real blobs contain no VINTRP instructions.** Neither embedded array has
  a `0xc8...` VINTRP word; the PS's interpolation-looking VOP words are lowered
  to `s_nop` by `gcn_decode`. Consequently the `!constantUvOnly` assertion is a
  weak structural check: `constantUvOnly` narrowly detects two `OpConstant
  %float` values forming an image-sample coordinate composite, while the real
  PS's coordinates come from dynamic-scalar `OpLoad`/`OpBitcast`/`OpSelect`
  values, so the assertion holds even before this change. **No VINTRP-derived
  interpolation is actually emitted for the real PS by this task** — recovering
  those ops (or their lossy GCN lowering) is still required for a genuinely
  guest-sourced UV and is out of Task 3's scope.
- Only `v_interp_p1_f32`/`v_interp_p2_f32` attrs are reconciled; `gcn_decode`
  has no `v_interp_mov_f32` tag, so MOV attrs cannot be checked here.
- A VINTRP/PARAM mismatch declares zero fragment inputs (with a diagnostic)
  for the registered pair; it does not invalidate the pair's translation. This
  preserves existing fixtures such as `"registration copies ISA..."` but means
  a live mismatched pair still produces a shader (with no interpolated inputs)
  rather than failing hard.
- Standalone `translateShader` calls (no registered program pair) still use the
  legacy `{ 0b11, 0b11 }` default; only the backend's program-keyed path uses
  the derived mask.
- `lastDiagnostic()` remains a single global (pre-existing), and the Task 2
  carry-over (once-only `tryRegisterRealShaders` firing with a partial bound
  pair) is unchanged.

---

## Fix round 1

Reviewer findings addressed: (1) the real Terraria PS produced no real UVs —
`fragmentInputsFromIsa` returned a mask from a VS PARAM export the PS never
consumed; (2) `!constantUvOnly` was vacuous for the real fixture.

### What changed

- `src/rdna2/spirv.zig` — new **default-off** option
  `Options.ps4_sample_coordinate_location: ?u8 = null` (mirrored as a `Builder`
  field). When set for a fragment stage:
  - `translateInstructions` adds the slot's bit to `effective.parameter_mask`,
    so a normal vec4 `Input` at that `Location` is declared even when the PS has
    no VINTRP words.
  - `sampleImage` replaces the 2D image-sample coordinate with `OpLoad` of that
    Input followed by `OpCompositeExtract` 0/1 and `OpCompositeConstruct`
    (vec2). The host-updated scalar address VGPRs no longer feed the sample.
  - Null (every native/PS5 path and standalone translation) emits exactly the
    previous words. No UV constant is fabricated.
- `src/ps4_mode/gcn_translate.zig` — for a registered pixel pair whose derived
  mask is nonzero, set the new option to the lowest exported PARAM slot
  (`@ctz(allocated)`). Standalone and mismatch paths leave it null.
- `src/ps4_mode/gcn_real_blob_test.zig` — added positive structural helper
  `inputFeedsImageSampleCoordinate(words, location)` that requires a Location-0
  **Input** variable, an `OpLoad` of it, `OpCompositeExtract` 0/1, a vec2
  `OpCompositeConstruct`, and that composite as the image-sample coordinate.
  It is now asserted positively; `!constantUvOnly` is retained only as a
  secondary guard. Added a PS4-gating test proving standalone pixel translation
  has no such Input.

### Covering tests

- `real PS fragment inputs come from VS PARAM exports and VINTRP attrs`
  (now asserts the positive Input→sample path).
- `input-fed UV is PS4-gated: standalone pixel translation has no such Input`.
- `VINTRP attr without a VS PARAM export reports null, never a guessed input`
  (unchanged anti-fabrication branch).

Non-vacuity was verified by temporarily forcing
`.ps4_sample_coordinate_location = null` in `buildOptions`: the positive test
then failed (`'gcn_real_blob_test.test.real PS fragment inputs come from VS
PARAM exports and VINTRP attrs' failed without output`, `1 failed`), and passed
again after restoring.

### Exact commands and output

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode --summary all
Build Summary: 3/3 steps succeeded; 58/58 tests passed
test-ps4mode success
+- run test 58 pass (58 total) 33ms MaxRSS:4M
   +- compile test ReleaseSafe native-native success 1m MaxRSS:821M
EXIT=0
```

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test --summary all
Build Summary: 62/62 steps succeeded; 2105/2136 tests passed (31 skipped)
EXIT=0
```

The 10 `failed command:` lines in the full log are the same pre-existing
harness noise documented in the earlier task reports; no test binary reported a
failure. Native/PS5 golden word tests are unchanged and green (option defaults
to null). Global Zig cache remained ~107 MB, under the 5 GB cap.

### Commit

`a758925 fix(ps4): route real-PS sample UV through declared VS PARAM input`
(only the three Task 3 files).

### Residual concerns

- The real GCN PS still has no VINTRP words; this fix supplies the interpolation
  through the Vulkan stage interface (VS PARAM0 export → Location-0 fragment
  Input), not through recovered GCN VINTRP instructions. If the guest VS's
  PARAM0 value is itself derived only from host-updated scalar slots, the UV is
  guest-shader-sourced but not yet a fully recovered guest attribute fetch.
- The override is limited to 2D image samples; other sampled-image dimensions
  keep their existing coordinate path.
- Only the lowest set PARAM bit is used as the UV slot; multiple exported PARAMs
  are not individually mapped.
