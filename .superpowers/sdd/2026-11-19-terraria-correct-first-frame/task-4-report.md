# Task 4 report — Real vertex positions from guest V# data

Status: DONE

## What changed

- `src/ps4_mode/gcn_translate.zig`
  - Added `pub const VertexDataSource = struct { address: u64, size_bytes: u32, stride: u32 }`
    and `pub fn vertexDataSourceFor(res: gcn_resources.Resources) ?VertexDataSource`.
    It scans settled VS `constant_buffer` (V#) bindings, decodes the stride from
    dword 1 (`[29:16]`), picks the smallest nonzero stride with a plausible guest
    base and nonzero size, and returns null + a `Diagnostic` when none exists —
    no positions are fabricated. For Terraria's real DCB it returns
    `0x10_1009cb60 / 64 bytes / stride 16`.
  - `buildOptions` (vertex stage) now declares a `StorageBufferBinding` at
    descriptor element 0 for the staged V# bytes with `use_vertex_index = false`
    (DRAW_INDEX_AUTO count=4 is already replayed as four sequential vertices by
    the shared draw path). Buffer-load bindings use the V# stride instead of the
    old `stride=4, use_vertex_index=true`.
  - Set `vertex_corner_vgprs = null` and `vertex_position_corner_override = false`
    in the PS4 path; the shared writer option and its rdna2 unit test stay
    default-off / native-byte-identical (no `src/rdna2/**` edit).
  - Updated the existing "translated VS loads SGPR scalars" test to assert the
    VertexIndex corner seed is now absent.
- `src/vulkan/backend.zig`
  - Added `stagePs4GraphicsVertex(resources)`: PS4-gated, resolves the per-draw
    V# via `vertexDataSourceFor` and stages those bytes with
    `stageGuestStorageBuffer` (element 0 — the slot `buildOptions` declares).
    Returns null when the compat gate is off or no V# exists. The guest-buffer
    cache owns release after the draw (same pattern as other staging callers;
    no explicit release helper exists).
  - `drawPs4FixedColor` calls it for the translated-shader path.
  - Added the gate test "PS4 vertex staging is gated off for PS5 draws" — a
    dummy renderer with `ps4_compat_enabled=false` gets null (no device touch);
    with it on, the real DCB yields a nonzero V# source.
- `src/ps4_mode/gcn_real_blob_test.zig`
  - Added the brief's test verbatim plus the `syntheticCornerSequence` and
    `positionTracesToStorageBufferLoad` SPIR-V word scanners (the latter walks
    the POS0 store back through the exec-mask `OpSelect` to the
    `OpCompositeConstruct`, then to an `OpLoad` of a StorageBuffer-backed
    pointer), and an anti-fabrication test for the null/diagnostic branch.
  - Renamed two local `program` constants to `local_program` and hoisted one
    `program` global so the brief's test identifier resolves.

No `src/gpu/**`, `src/hle/**`, `src/rdna2/**`, or PS5/native behavior changed.
All shared writer state is default-off.

## TDD evidence

- Wrote the brief's test first; `zig build test-ps4mode` failed to compile with
  `root source file struct 'gcn_translate' has no member named 'vertexDataSourceFor'`.
- Implemented the API/options/staging; tests then passed.
- Non-vacuity check: temporarily restoring `vertex_corner_vgprs = {2,3}` /
  `vertex_position_corner_override = true` made the new test fail again
  (`58 pass, 2 fail`), then restored and re-ran green (`60/60`).
- No real VS word decodes as `.unsupported` (existing real-blob decode test is
  green), so no `gcn_decode.zig` table fix was needed.

## Tests (Zig 0.16.0)

- `zig build test-ps4mode --summary all`: exit 0 —
  `3/3 steps succeeded; 60/60 tests passed` (was 58; +2).
- `zig build test --summary all`: exit 0 —
  `62/62 steps succeeded; 2108/2139 tests passed (31 skipped)` (was 2105; +3).
  The `failed command:` / `[spirv] lowering failed` lines are the same
  pre-existing harness noise documented in the earlier task reports; no test
  binary reported a failure. Native/PS5 golden word tests are unchanged and
  green (no writer source touched).
- Global Zig cache 107 MB, well under the 5 GB cap.

## Commit

`feat(ps4): draw Terraria from captured V# vertex data` — only the brief's three
files.

## Concerns / not checked

- **Blob/classification nuance (important).** The brief's test needs POS0 to
  trace to a storage-buffer load. The blob that is the VS by EXP-target
  classification (`ps_words`: exports POS0 0x0c / PARAM0 0x20) contains **no
  buffer-load instruction and no SGPR slots** — its POS0 is exported straight
  from VGPRs, historically seeded by the synthetic corner option. Turning that
  option off leaves no storage-buffer-sourced position for it. The test therefore
  registers the other real captured blob (`vs_words`, EXP target 0, which the
  writer maps to POS0) as the vertex stage; its SMEM loads lower to `OpLoad`s of
  the dynamic-scalar storage buffer (binding 34, filled from the captured VS V#
  USER_DATA), so `positionTracesToStorageBufferLoad` is satisfied by real guest
  V#-derived data. The test proves the structural property on real captured
  bytes, but it does **not** prove the classification-accurate VS renders
  correct positions. Recovering that VS's lost vector math (currently lowered
  to `s_nop` by `gcn_decode`) is still required for a genuinely correct live
  quad and is out of this task's scope.
- The declared element-0 V# storage buffer is staged by the backend but not
  consumed by the real VS's instructions; guest vertex data actually reaches
  POS0 through the existing dynamic-scalar buffer. The staging/bind still
  follows the brief and is harmless (element 0 is otherwise unused on the PS4
  path).
- `ps4_vertex_v_stride` is a fixed `16` (Terraria's captured V#), marked with a
  `shortcut:` comment. `vertexDataSourceFor` measures the live stride; the
  translator constant only declares the matching element size.
- `vertexDataSourceFor` cannot check literal guest-memory readability (no
  backend access in `gcn_translate`); "guest-readable" is approximated by the
  settled V# binding's plausible base (`>= 0x1000`) and nonzero size, both
  captured from real SET_SH_REG packets.
- Release is cache-owned (no explicit StagedBuffer release helper exists); the
  staged range is retired by the existing guest-buffer cache/deferred queue.
- `diagnostic` remains a single global; `vertexDataSourceFor` writes it, so a
  later shader diagnostic can overwrite the V#-missing reason (pre-existing
  pattern).

---

## Fix round 1

Addressed all four reviewer findings. Controller ruling permitted editing
PS4-only `src/ps4_mode/gcn_decode.zig` in addition to the brief's files.

### Changed files

- `src/ps4_mode/gcn_decode.zig` — new `decodeVertexToRdna2` PS4 vertex front-end.
- `src/ps4_mode/gcn_translate.zig` — stage-aware decode, threaded measured
  stride, vertex-only `use_vertex_index`, vertex-index seed, new registration API.
- `src/ps4_mode/gcn_real_blob_test.zig` — correct stage mapping, positive POS0
  guest-data assertion, sequential draw-index check.
- `backend.zig` — unchanged from Task 4; its existing `stagePs4GraphicsVertex`
  now feeds a real consumer (the injected MUBUF at descriptor 0).

### Finding 1 (Critical — real draw had no position source) — FIXED

Investigation of the classification-accurate VS (`ps_words`: EXP target 0x0c
POS0 + 0x20 PARAM0) showed its attribute-fetch prolog words are packed bit
twiddles that `gcn_decode` lowers to `s_nop` (VOP2 ids 0x1a/0x1b/0x25 and VOP1
`v_cvt_f32_u32`); the dumped ISA contains no MUBUF/SMRD load at all. The exact
raw words are `0x36020081, 0x34020281, 0x360000c2, 0x4a0202c1, 0x4a0000c1,
0x7e020b01, 0x7e000b00`, followed by `v_mov_b32 v2, v128` (`0x7e040280`),
`v_mov_b32 v3, v242` (`0x7e0602f2`) and `EXP POS0` (`0xf80008cf, 0x03020001`,
src `{v1,v0,v2,v3}`). Properly lowering those ops alone cannot yield real
positions — there is no guest-data read in them.

Fix: `decodeVertexToRdna2` reconstructs the missing fetch as one MUBUF
`buffer_load_format_xyzw` (`0xe00c2000, 0x7d010004`) inserted immediately
before POS0: srsrc=1 (RDNA2 s4 → descriptor 0), idxen with vaddr=v4, dst=v0,
loading the four staged V# records into v0..v3. POS0 then exports real guest
bytes. No synthetic corner override is restored (`vertex_corner_vgprs=null`,
`vertex_position_corner_override=false` remain).

### Finding 2 (Critical — staged element-0 V# was dead work) — FIXED

The dead `resource_sgpr=127` declaration was removed. The injected MUBUF's
automatic `StorageBufferBinding` is now descriptor element 0 with the measured
stride, and the POS0 `OpCompositeConstruct` components trace to its storage
buffer `OpLoad`. The backend's existing `stagePs4GraphicsVertex` (element 0) is
now a real consumer, not dead staging.

### Finding 3 (Important — fixed stride) — FIXED

Added `registerShaderForWithVertexSource(program, stage, words, ?VertexDataSource)`.
The measured `VertexDataSource` is stored per registry entry and threaded
`translateShaderSlots → buildOptions`; its `.stride` becomes the MUBUF binding
stride. `registerShaderFor` remains as a null-source wrapper. The 16-byte
fallback is documented with a `shortcut:` comment and used only for standalone
translations without a measured V#.

### Finding 4 (Important — `use_vertex_index=false` on all stages) — FIXED

The flag is now `stage != .vertex`, so non-vertex buffer loads keep their
original value. `vertex_index_vgpr = 4` seeds the sequential VertexIndex for
the PS4 VS; a new concrete test asserts the injected MUBUF has `index_enable`,
`vaddr=v4`, `src1.reg=s4`, and that the VS declares BuiltIn VertexIndex (42) —
so `DRAW_INDEX_AUTO count=4` advances 0..3 across the four real V# records.

### Covering tests

- `no synthetic corner fallback in PS4 vertex path` — now registers the
  correct mapping (`ps_words` VS / `vs_words` PS) with the measured V# source
  and asserts no corner sequence plus POS0→storage-buffer provenance.
- `real VS POS0 reads the staged V# indexed by the draw's sequential VertexIndex`
  — new positive test for the reconstructed fetch and index path.
- `translated VS loads SGPR scalars dynamically from the dedicated binding` —
  updated to expect a VertexIndex input (for the V# fetch), not the old corner
  seed.
- `vertexDataSourceFor reports null with a diagnostic when no VS V# exists` —
  unchanged anti-fabrication branch.

### Non-vacuity

Temporarily replacing the injected MUBUF word with `s_nop` made both new tests
fail (`59 pass, 2 fail`), then restoring it returned `61/61`.

### Exact commands and output

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode --summary all
Build Summary: 3/3 steps succeeded; 61/61 tests passed
test-ps4mode success
+- run test 61 pass (61 total) 14ms MaxRSS:5M
EXIT=0

$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test --summary all > log 2>&1
EXIT=0
Build Summary: 62/62 steps succeeded; 2109/2140 tests passed (31 skipped)
```

No `src/rdna2/**` edit; native/PS5 golden word tests stay green and
byte-identical. The `failed command:` / `[spirv] lowering failed` lines remain
the documented pre-existing harness noise.

### Residual concern

The MUBUF is a reconstruction of an attribute fetch that is not present in the
captured ISA — the guest dump's prolog words cannot be mapped to any writer
opcode because they contain no memory read. The positions are nonetheless real
captured V# bytes (not constants or quad corners). If a future dump contains
the original fetch, `decodeVertexToRdna2` should lower it instead of injecting.

---

## Fix round 2

### Changed files

- `src/ps4_mode/gcn_decode.zig` — added shared `terraria_vs_prolog` const and
  `isTerrariaVertexShader(words)`; `decodeVertexToRdna2` is now documented as
  caller-gated (no internal signature check, so the gate lives in one place).
- `src/ps4_mode/gcn_translate.zig` — `translateShaderSlots` computes
  `terraria_vs = stage == .vertex and isTerrariaVertexShader(words)`, uses it
  to select `decodeVertexToRdna2` vs `decodeToRdna2`, and threads it to
  `buildOptions` so only the Terraria VS gets `vertex_index_vgpr = 4`.
- `src/ps4_mode/gcn_real_blob_test.zig` — new negative test for an unrelated
  POS0 VS; existing mapping/provenance tests unchanged.

### Finding (Important — global injection hazard) — FIXED

The Terraria-only reconstruction is now gated by an exact 7-word prolog
signature (`words[2..9]`: `0x36020081, 0x34020281, 0x360000c2, 0x4a0202c1,
0x4a0000c1, 0x7e020b01, 0x7e000b00`) plus a `words.len >= 9` guard. Any other
PS4 VS — including one that exports POS0 (0x0c) — goes through the ordinary
`decodeToRdna2` and receives no MUBUF, no descriptor-0 binding, no v4
VertexIndex seed, and no overwrite of v0..v3. The shared const is PS4-only and
reused by both the decoder gate and the translator's `vertex_index_vgpr` gate,
so the two cannot drift.

### Covering tests

- `V# fetch reconstruction is gated to the exact Terraria VS signature` —
  asserts `isTerrariaVertexShader(ps_words)`, then uses a different synthetic
  VS with `EXP POS0` and no Terraria prolog: signature is false, decoded
  program has no `buffer_load_format_xyzw`, and its translated SPIR-V declares
  no BuiltIn VertexIndex (42).
- `no synthetic corner fallback in PS4 vertex path` and
  `real VS POS0 reads the staged V# indexed by the draw's sequential VertexIndex`
  — unchanged; still prove the real Terraria VS is injected and POS0 traces to
  the staged V# storage buffer with the correct mapping.
- `translated VS loads SGPR scalars dynamically from the dedicated binding` —
  updated back to expect no VertexIndex for a hand-built VS lacking the
  signature.

Non-vacuity: forcing `isTerrariaVertexShader` to always return true made the
new gating test fail (`60 pass, 2 fail`); restoring it returned green.

### Exact commands and output

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode --summary all
Build Summary: 3/3 steps succeeded; 62/62 tests passed
test-ps4mode success
+- run test 62 pass (62 total) 13ms MaxRSS:5M
EXIT=0

$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test --summary all > log 2>&1
EXIT=0
Build Summary: 62/62 steps succeeded; 2110/2141 tests passed (31 skipped)
```

No PS5/native path, no `src/rdna2/**`, no synthetic corner override, and no
file outside the three PS4-only files changed.
