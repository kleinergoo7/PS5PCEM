# GCN → SPIR-V first milestone — implementation report

**Date:** 2026-11-19
**Worktree:** `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-shader` (branch `gcn-shader`, base `3309ec5`)
**Status:** DONE — tests pass, committed.

## What was implemented

### New PS4-only modules

- **`src/ps4_mode/gcn_decode.zig`** — authoritative GCN (GFX6/7) top-level
  decoder. Correct family dispatch from word0 encoding bits (does not touch
  `gcn_lower.classify`). Exposes a tagged `Instruction` union and a
  `decode(words)` iterator, plus `decodeAll`/`decodeToRdna2`.
  - Decoded: SOP1 (`s_mov_b32` 0x00, `s_mov_b64` 0x01), SOPP (`s_endpgm`,
    `s_branch` 0x02, `s_cbranch_scc0/1` 0x04/0x05, `s_waitcnt` 0x0c/0x17–0x1a),
    SMRD (`s_load_dwordx4` 0x02, `s_buffer_load_dwordx4` 0x0a), VOP2
    (`v_add/sub/subrev/mul/min/max/mac_f32`), VOP1 (`v_mov_b32`), VOPC, VOP3
    (`v_mad_f32` 0x141), VINTRP (p1/p2), MUBUF (`buffer_load_format_xyzw` op 3),
    MIMG (`image_sample` 0x20 + DMASK), EXP (0x3E base, TARGET/EN).
  - Normalizes the families whose layouts differ into the GFX10 words the
    existing `rdna2.decodeProgram` consumes: SOP1 opcode shift (GCN 0x00→RDNA2
    0x03), 1-word SMRD → 2-word SMEM, MIMG DIM forced to 2D, `s_waitcnt` →
    `s_nop` (preserves byte PCs). SOPP/VOP/VINTRP/MUBUF/EXP word layouts are
    already identical for GCN 1.0/1.1.
  - Literal operands grow `word_count` and are consumed as an extra word.
  - Unsupported instructions/families yield `Instruction.unsupported` with a
    reason rather than being skipped.

- **`src/ps4_mode/gcn_translate.zig`** — PS4 integration API:
  - `pub const TranslatedGraphics = struct { vertex_words, fragment_words }`
  - `pub fn translatedGraphics() ?TranslatedGraphics`
  - `pub fn registerShader(stage: enum{vertex,pixel}, words: []const u32) void`
  - `translateShader(allocator, stage, words)` returns owned SPIR-V words and
    errors with `error.UnsupportedInstruction` if any GCN instruction is
    unsupported.
  - PS4 options/resource builder derives `sampled_images` (T#/S# SGPR pair from
    MIMG), `storage_buffers` (V# SGPR from MUBUF), sets fragment inputs, and
    lets the shared writer infer `parameter_mask`/`color_export_mask` from
    VINTRP/EXP. **No SPIR-V emission is reimplemented** — `rdna2.translateProgramSpirv`
    does all emission.
  - Registration owns copies of ISA and translated words, invalidates the old
    translation on change, and records a diagnostic (`lastDiagnostic()`).

### Wiring
- `src/ps4_mode/root.zig` exports both modules and pulls their tests into
  `test-ps4mode`.
- `build.zig`: added the existing `rdna2` module as an import of `ps4_mode`
  only (no cycle; no PS5/shared module changed).

### Tests (41 in test-ps4mode; 6 new)
- GCN top-level family dispatch uses real encoding numbers.
- Sprite pixel shader decode yields the exact instruction sequence; asserts
  image DMASK, T#/S# SGPRs and EXP MRT0 target/EN/DONE.
- SOPP branch target uses word-scaled byte offsets.
- SMRD re-encodes to a two-word RDNA2 SMEM load with correct PC shift.
- Sprite PS translation emits `OpImageSampleImplicitLod` (87), `OpFMul` (133)
  and an `OpDecorate Location 0` (MRT0 export target).
- Vertex POS/PARAM exports translate.
- Unsupported instructions (DS family, bad VOP2 opcode) are reported, not
  dropped.
- Registration copies words, returns null until both stages are present, and
  invalidates on change.

## Exact test output

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
  /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode --summary all
Build Summary: 3/3 steps succeeded; 41/41 tests passed
test-ps4mode success
+- run test 41 pass (41 total) 5ms MaxRSS:5M
   +- compile test ReleaseSafe native-native success 36s MaxRSS:789M
```

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
  /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test
(exit 0)
$ ... zig build test --summary all
Build Summary: 62/62 steps succeeded; 2085/2116 tests passed (31 skipped)
```

## What works / what is still unsupported

**Works:** correct GCN family dispatch and the listed instruction subset;
GCN→RDNA2 normalization for SOP1/SMRD/MIMG/waitcnt; shared SPIR-V writer
reuse for VS and PS; explicit unsupported-instruction reporting; PS4-only
register/translate API with invalidation.

**Still unsupported (deliberate milestone-1 scope):**
- DS/LDS, FLAT, MTBUF, GDS, atomics, tessellation, VOP3P/f16, gather4,
  DPP/SDWA, SOP2/SOPC/SOPK semantics, `v_interp_mov_f32`.
- `v_mad_f32` is decoded with the 10-bit OP[25:16] (GCN 1.2 / RDNA2) form;
  GCN 1.0/1.1 9-bit VOP3 opcodes are not shifted.
- GFX9 byte-permuted MUBUF word1 is not handled (GCN 1.0/1.1 layout assumed).
- SMRD 2-word literal-offset (CI) form not handled; 1-word form assumed.
- Resource bindings are derived from instruction SGPRs with stub descriptor
  indices; real GNM T#/S#/V# descriptors and `SPI_PS_INPUT_ADDR/ENA` are not
  recovered from guest memory. Image sample is fixed to 2D.
- No PS4 draw path is wired (`backend.zig` untouched) — `translatedGraphics()`
  is the integration seam, returns null until real shaders are registered.

## Concerns

- No real Terraria GCN blob exists in the repo (`gcn-vs.bin`/`gcn-ps.bin` are
  zero-filled); fixtures are hand-encoded from the documented GCN microcode
  layout and the feasibility spec's opcode table. A live guest-memory dump is
  needed to confirm the exact GCN generation and MUBUF/SMRD word layouts.
- `translatedGraphics()` returns slices into globals protected by a mutex
  during registration; a caller holding slices across a concurrent
  `registerShader` could observe freed memory. Fine for a single render thread,
  needs a lifetime scheme before multi-threaded use.
- `s_waitcnt` is lowered to `s_nop` (sync semantics dropped by design);
  `shortcut:` comments mark the layout assumptions.

**Skipped / not checked:** no `spirv-val` validation of emitted modules (tests
assert opcode presence, not full validity); no live-GCN decode; no PM4/draw
wiring; no GFX9/GFX10 GCN generation detection. Risk: the shipped PS4 compiler
may use GCN 1.0/1.1 VOP3/VOPC encodings or a different MUBUF word1 layout,
which would need a small decoder adjustment once a real shader is captured.
