# Terraria Correct First Frame Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render Terraria's first presented frame from the game's own geometry, UVs, shaders and textures, with no synthetic positions, UVs or colors.

**Architecture:** PS4-only modules decode GCN resources and shaders; the existing `rdna2` writer and Vulkan backend do all emission and drawing. Each submitted DCB produces an ordered set of per-draw resource snapshots, consumed in draw order by the PS4-gated draw. All shared code changes are behind default-off options, with byte-identity tests.

**Tech Stack:** Zig 0.16.0, vendored PS4 mode modules, `rdna2/spirv.zig`, Vulkan backend, X11 screenshot + ImageMagick histogram for visual verification.

**Spec:** `docs/superpowers/specs/2026-11-19-terraria-correct-first-frame-design.md`

## Global Constraints

- Zig 0.16.0 at `/home/reng/tools/zig-x86_64-linux-0.16.0/zig`; global cache `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`; hard cap 5 GB.
- PS5 paths stay native and unchanged; shared writer changes only behind default-off options with byte-identity tests.
- No separate PS4 renderer; GNM packets flow through the shared translate/lower/execute path.
- No fabricated pixels: no probe triangle, synthetic corner positions, checkerboard texture, or constant UV in the final path.
- Every task ends with a commit; full `zig build test` stays green.
- The authoritative extracted tree is `/tmp/opencode/verify-b` (read-only input).

## Review Focus

| Failure mode / input | Expected behavior | Test that pins it (owning task) |
|---|---|---|
| One DCB contains two draws with different PS T#s (the real fixture) | Each draw binds its own T#; no last-write-wins collapse | `"per-draw snapshots keep distinct PS textures"` (Task 1) |
| Two successive submissions use the same program pair but different resources | Resources follow submission order, not a global slot | `"capture FIFO is ordered for equal program pairs"` (Task 1) |
| Shader blobs found by scan do not match the program the draw binds | Translation is looked up by the bound program pair; mismatch is an error/absence, not a wrong shader | `"program-keyed translation rejects mismatched pair"` (Task 2) |
| Vertex data cannot be recovered from the captured V# | Report the exact missing descriptor; never fall back to synthetic corners | `"no synthetic corner fallback in PS4 vertex path"` (Task 4) |
| PS4 mode off (`ps4_compat_enabled = false`) | No resource capture, no PS4 draw, native output byte-identical | `"PS4 draw path is fully gated"` (Task 1, rechecked Task 6) |

---

### Task 1: Ordered per-draw resource capture

**Files:**
- Modify: `src/ps4_mode/gcn_resources.zig` (replace global `captured_resources`/`publish`/`captured` at lines ~148-173)
- Modify: `src/ps4_mode/root.zig` (re-export `ProgramPair`)
- Modify: `src/hle/libs/gnm_compat.zig:102-104` (submit-boundary publish call)
- Modify: `src/vulkan/backend.zig` (`ps4GraphicsScalars:25752`, `ps4SampledImageDescriptor:25802`, `stagePs4GraphicsSampledImage`, `drawPs4FixedColor:25881`, gate test near `:49514`)
- Test: `src/ps4_mode/gcn_resources.zig` test block, `src/vulkan/backend.zig` test block

**Interfaces:**
- Consumes: `gcn_resources.capture(words) Resources` (existing packet walker), `shader_binding.programs()` returning `pm4_sanitize.ShaderPrograms`.
- Produces:
  ```zig
  pub const ProgramPair = struct { vertex: u64 = 0, pixel: u64 = 0 };
  pub const max_draws_per_capture: usize = 8;
  pub const max_capture_queue: usize = 8;
  pub const Capture = struct { draws: [max_draws_per_capture]Resources = undefined, count: usize = 0 };
  pub fn capture(words: []const u32) Capture;       // snapshot Resources at each DRAW_INDEX_AUTO (0x2d)
  pub fn publish(cap: Capture) void;                // append to FIFO, reset draw cursor
  pub fn nextDrawResources() ?Resources;            // consume snapshots in submit/draw order
  pub fn resetCapture() void;
  ```
  `capture` keeps the existing whole-DCB `Resources` result for the no-draw case as `draws[0]` when `count == 0`. `nextDrawResources` clamps to the last snapshot when a submit has more draws than snapshots; returns null only when nothing was published.

- [ ] **Step 1: Write the failing tests**

In `gcn_resources.zig` add:
```zig
test "per-draw snapshots keep distinct PS textures" {
    // Build two DCBs: each sets a different PS T# USER_DATA then issues
    // DRAW_INDEX_AUTO (0x2d). Use real dwords from terraria_frame_test.zig.
    resetCapture();
    publish(capture(&dcb_a)); // PS T# 0x10170c0000
    publish(capture(&dcb_b)); // PS T# 0x10168c8000
    const a = nextDrawResources().?;
    const b = nextDrawResources().?;
    try std.testing.expectEqual(@as(u64, 0x10170c0000), psImage(a).?.address);
    try std.testing.expectEqual(@as(u64, 0x10168c8000), psImage(b).?.address);
}

test "capture FIFO is ordered for equal program pairs" {
    resetCapture();
    publish(capture(&dcb_with_two_draws)); // snapshots: T# A, T# B
    const first = nextDrawResources().?;
    const second = nextDrawResources().?;
    try std.testing.expectEqual(@as(u64, 0x10170c0000), psImage(first).?.address);
    try std.testing.expectEqual(@as(u64, 0x10168c8000), psImage(second).?.address);
    try std.testing.expect(nextDrawResources() != null); // clamp to last
}
```
`psImage(res)` is a small test helper returning the last sampled-image descriptor for `.pixel`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/reng/projects/ps5_zig_emu/PS5PCEM_PS4Mode && ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 /home/reng/tools/zig-x86_64-linux-0.16.0/zig build test-ps4mode`
Expected: compile error — `Capture`/`nextDrawResources` undefined.

- [ ] **Step 3: Implement per-draw snapshots in `gcn_resources.zig`**

Define `ProgramPair` in `gcn_resources.zig` and re-export it from `src/ps4_mode/root.zig`. Split the packet walker so it snapshots `userData` rows and typed bindings each time it sees opcode `0x2d`; store snapshots in `Capture.draws`. Keep the existing whole-DCB result as `draws[0]` when no draw packet appears. Run `zig build test-ps4mode` until `"per-draw snapshots keep distinct PS textures"` passes.

- [ ] **Step 4: Implement the capture FIFO in `gcn_resources.zig`**

Replace `captured_resources`/`captured_valid` with a `[max_capture_queue]Capture` ring, a head/tail cursor and a per-capture draw cursor. `publish` appends; `nextDrawResources` returns the next draw snapshot of the oldest capture and advances, popping when exhausted. Keep the spin-lock; no allocation. Run `zig build test-ps4mode` until `"capture FIFO is ordered for equal program pairs"` passes.

- [ ] **Step 5: Update callers**

In `gnm_compat.zig:102-104`: change the call to `ps4_mode.gcn_resources.publish(ps4_mode.gcn_resources.capture(slice));`. In `backend.zig`: change `ps4GraphicsScalars`, `ps4SampledImageDescriptor`, `stagePs4GraphicsSampledImage` to take `resources: ps4_mode.gcn_resources.Resources`; in `drawPs4FixedColor` call `nextDrawResources() orelse return Error.UnsupportedGraphicsState` once at entry and pass it through. Update tests calling `captured()` (near `:49514`, `:49557`). Run `zig build test-ps4mode`; expect PASS.

- [ ] **Step 6: Run full tests to verify they pass**

Run: `zig build test-ps4mode`
Expected: PASS, including the two new tests and all existing PS4 tests.
Then: `zig build test` — exit 0.

- [ ] **Step 7: Verify PS5 gate**

Run the existing gate test near `backend.zig:49557` with `ps4_compat_enabled=false`; confirm no capture or draw call. Add an assertion that `stagePs4GraphicsSampledImage` returns null when the flag is off.

- [ ] **Step 8: Commit**

```bash
git add src/ps4_mode/gcn_resources.zig src/ps4_mode/root.zig src/hle/libs/gnm_compat.zig src/vulkan/backend.zig
git commit -m "feat(ps4): carry GPU resources per draw instead of last-DCB-wins"
```

---

### Task 2: Program-keyed shader translation

**Files:**
- Modify: `src/ps4_mode/gcn_translate.zig` (registry at ~`:196-255`)
- Modify: `src/hle/libs/ps4_title_stubs.zig` (`tryRegisterRealShaders`, `setPsShader`, `setVsShader` near `:30-115`)
- Modify: `src/vulkan/backend.zig` (`drawPs4FixedColor:25881`)
- Test: `src/ps4_mode/gcn_real_blob_test.zig`

**Interfaces:**
- Consumes: `ProgramPair` from Task 1 (re-exported from `ps4_mode/root.zig`); `shader_binding.programs()` returns `pm4_sanitize.ShaderPrograms` with `.vertex`, `.pixel`, which converts to `ProgramPair`.
- Produces:
  ```zig
  pub fn registerShaderFor(program: ProgramPair, stage: Stage, words: []const u32) void;
  pub fn translatedGraphicsFor(program: ProgramPair) ?TranslatedGraphics;
  pub fn scalarSlotsFor(program: ProgramPair, stage: Stage) []const ScalarSlot;
  ```
  Existing `registerShader`/`translatedGraphics` remain as test-only helpers over a zero program pair.

- [ ] **Step 1: Write the failing test**

In `gcn_real_blob_test.zig`:
```zig
test "program-keyed translation rejects mismatched pair" {
    const program: ProgramPair = .{ .vertex = 0x1000000a88, .pixel = 0x1000000aa4 };
    registerShaderFor(program, .vertex, &real_vs_isa);
    registerShaderFor(program, .pixel, &real_ps_isa);
    try std.testing.expect(translatedGraphicsFor(program) != null);
    try std.testing.expect(translatedGraphicsFor(.{ .vertex = 1, .pixel = 2 }) == null);
}
```
Use the embedded real ISA arrays already in this test file.

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test-ps4mode`
Expected: compile error — `registerShaderFor` undefined.

- [ ] **Step 3: Implement the program-keyed registry in `gcn_translate.zig`**

Replace the four globals `vertex_isa/pixel_isa/vertex_spirv/pixel_spirv` with a bounded `[8]ShaderTranslation` registry keyed by `ProgramPair`; each entry owns both stage ISAs, translated SPIR-V words and scalar slots. `registerShaderFor` inserts/refreshes one stage and retranslates the pair when both are present. `translatedGraphicsFor` returns null unless both stages for the exact pair are present. Run `zig build test-ps4mode` until the new program-key test passes.

- [ ] **Step 4: Update registration and draw callers**

In `ps4_title_stubs.zig`, pass `shader_binding.programs()` into `registerShaderFor` at both shader-set imports. In `backend.zig`, query `translatedGraphicsFor(shader_binding.programs())` instead of the global; pass the same pair to `scalarSlotsFor`. Run `zig build test-ps4mode`; expect PASS.

- [ ] **Step 5: Run full tests to verify they pass**

Run: `zig build test-ps4mode` → PASS; `zig build test` → exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/ps4_mode/gcn_translate.zig src/hle/libs/ps4_title_stubs.zig src/vulkan/backend.zig src/ps4_mode/gcn_real_blob_test.zig
git commit -m "feat(ps4): key translated shaders to the bound GNM program pair"
```

---

### Task 3: Real UV from VINTRP and VS PARAM exports

**Files:**
- Modify: `src/ps4_mode/gcn_translate.zig` (`buildOptions:~136-190`)
- Modify: `src/rdna2/spirv.zig` (only if `FragmentInputs` needs an added field; default-off)
- Test: `src/ps4_mode/gcn_real_blob_test.zig`

**Interfaces:**
- Consumes: `gcn_decode.Vintrp` (`.attr`, `.op`) and `gcn_decode.Exp` (`.target`) from `gcn_decode.zig`; the registered VS program from Task 2.
- Produces:
  ```zig
  pub const FragmentInputs = struct { allocated: u32, enabled: u32 };
  pub fn fragmentInputsFor(program: ProgramPair) ?FragmentInputs;
  ```
  `buildOptions` for `.pixel` uses this instead of the hardcoded `.{ .allocated = 0b11, .enabled = 0b11 }`.

- [ ] **Step 1: Write the failing test**

```zig
test "real PS fragment inputs come from VS PARAM exports and VINTRP attrs" {
    // register VS+PS real blobs under a program pair, then:
    const inputs = fragmentInputsFor(program).?;
    try std.testing.expectEqual(@as(u32, expected_param_mask_from_vs_exp), inputs.allocated);
    try std.testing.expectEqual(inputs.allocated, inputs.enabled);
    // The translated PS must contain a VINTRP-derived interpolation, not a constant UV:
    try std.testing.expect(!constantUvOnly(translatedGraphicsFor(program).?.fragment_words));
}
```
`constantUvOnly` scans the SPIR-V words for the current constant-UV pattern (two `OpConstant` floats fed to the image coordinate); write it in the test file.

- [ ] **Step 2: Run it to verify it fails** — `zig build test-ps4mode`, expect failure on `fragmentInputsFor` undefined / constant UV assertion.

- [ ] **Step 3: Decode PARAM exports and VINTRP attrs**

Add a helper in `gcn_translate.zig` that walks the registered VS's decoded `exp` instructions with target `>= 0x20` and maps `target - 0x20` to a bit in `allocated/enabled`. For the pixel stage, walk decoded `Vintrp` instructions and require their `.attr` indices to be covered by that mask; if not, report a diagnostic and return null rather than guessing. Pass the result to `rdna2.spirv.Options.fragment_inputs` in `buildOptions`.

- [ ] **Step 4: Run tests to verify it passes** — `zig build test-ps4mode` → PASS; `zig build test` → exit 0; confirm the PS5 byte-identity tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/ps4_mode/gcn_translate.zig src/rdna2/spirv.zig src/ps4_mode/gcn_real_blob_test.zig
git commit -m "feat(ps4): derive PS fragment inputs from GCN VINTRP and VS PARAM exports"
```

---

### Task 4: Real vertex positions from guest V# data

**Files:**
- Modify: `src/ps4_mode/gcn_translate.zig` (vertex `buildOptions`, storage buffer declaration)
- Modify: `src/vulkan/backend.zig` (`drawPs4FixedColor:25881`, new PS4 vertex staging helper)
- Test: `src/ps4_mode/gcn_real_blob_test.zig`, `src/vulkan/backend.zig` test block

**Interfaces:**
- Consumes: per-draw `Resources` from Task 1 (`vertex_user_data`, `Binding{kind=.constant_buffer}`), `translatedGraphicsFor` from Task 2.
- Produces:
  ```zig
  pub const VertexDataSource = struct { address: u64, size_bytes: u32, stride: u32 };
  pub fn vertexDataSourceFor(res: gcn_resources.Resources) ?VertexDataSource;
  ```
  Backend stages this through the existing `stageGuestStorageBuffer(guest_address, size)` (`backend.zig:8851`) and binds it at the `StorageBufferBinding.descriptor_index` declared by `buildOptions`.

- [ ] **Step 1: Write the failing tests**

In `gcn_real_blob_test.zig`:
```zig
test "no synthetic corner fallback in PS4 vertex path" {
    const res = capture(&real_terraria_dcb).draws[0];
    const src = vertexDataSourceFor(res).?;
    try std.testing.expect(src.address != 0);
    try std.testing.expect(src.size_bytes > 0);
    const spirv = translatedGraphicsFor(program).?.vertex_words;
    try std.testing.expect(!syntheticCornerSequence(spirv));
    try std.testing.expect(positionTracesToStorageBufferLoad(spirv));
}
```
`syntheticCornerSequence` detects the current `VertexIndex & 1 / >>1` bitcast pattern; `positionTracesToStorageBufferLoad` checks the Position `OpCompositeConstruct` components come from an `OpLoad` of a storage buffer. In `backend.zig`, extend the gate test to assert no vertex staging occurs when `ps4_compat_enabled=false`.

- [ ] **Step 2: Run them to verify they fail** — `zig build test-ps4mode`, expect failure on `vertexDataSourceFor` undefined.

- [ ] **Step 3: Use the guest vertex table and remove the synthetic override**

If `gcn_decode.zig` reports `.unsupported` on any real VS word, first fix that word's family dispatch or opcode table in `gcn_decode.zig`; re-run the real-blob test until translation succeeds. In `vertexDataSourceFor`, select the VS V# binding with the smallest nonzero `stride` whose address is guest-readable; return null with a diagnostic if none exists (never fabricate). In `buildOptions` for `.vertex`, build `StorageBufferBinding` from that source with the measured stride and `use_vertex_index = false` only after confirming `DRAW_INDEX_AUTO` supplies sequential indices; set `vertex_corner_vgprs = null` and `vertex_position_corner_override = false` on the final PS4 path. In `backend.zig`, stage the guest vertex bytes with `stageGuestStorageBuffer`, bind them at the translator's declared descriptor index, release after the draw, and treat `DRAW_INDEX_AUTO count=4` as four sequential vertices. Do not relax any shared register or topology check.

- [ ] **Step 4: Run tests to verify they pass** — `zig build test-ps4mode` → PASS; `zig build test` → exit 0. Confirm the native `rdna2` byte-identity test still passes.

- [ ] **Step 5: Commit**

```bash
git add src/ps4_mode/gcn_translate.zig src/vulkan/backend.zig src/ps4_mode/gcn_real_blob_test.zig
git commit -m "feat(ps4): draw Terraria from captured V# vertex data"
```

---

### Task 5: Select each draw's real PS texture

**Files:**
- Modify: `src/ps4_mode/gcn_translate.zig` (sampled-image resource index)
- Modify: `src/vulkan/backend.zig` (`ps4SampledImageDescriptor`, `stagePs4GraphicsSampledImage`)
- Test: `src/ps4_mode/gcn_real_blob_test.zig`

**Interfaces:**
- Consumes: decoded PS `Mimg.tsgpr` and `OptionsBuilder.images` (`resource_sgpr`), per-draw `Resources` from Task 1.
- Produces:
  ```zig
  pub fn sampledImageUserIndexFor(program: ProgramPair) ?u8;
  ```
  Returns the USER_DATA word index backing the PS's sampled image (GCN SGPR number minus the stage USER_DATA base, adjusted for the decoded resource SGPR).

- [ ] **Step 1: Write the failing test**

```zig
test "PS image samples the USER_DATA slot of its own draw" {
    const index = sampledImageUserIndexFor(program).?;
    const first = nextDrawResources().?;   // Task 1 FIFO
    const second = nextDrawResources().?;
    try std.testing.expectEqual(@as(u64, 0x10170c0000), first.userData(.pixel)[index] << 8);
    try std.testing.expectEqual(@as(u64, 0x10168c8000), second.userData(.pixel)[index] << 8);
}
```

- [ ] **Step 2: Run it to verify it fails** — `zig build test-ps4mode`, expect `sampledImageUserIndexFor` undefined.

- [ ] **Step 3: Use the decoded resource slot**

In `gcn_translate.zig`, derive the index from the PS's decoded `Mimg.tsgpr` / `SampledImageBinding.resource_sgpr`. In `backend.zig`, replace the "last PS T#" loop in `ps4SampledImageDescriptor` with a lookup by `binding.user_data_index == sampledImageUserIndexFor(program)` on the per-draw resources. Keep the existing detiling/format conversion. Remove any checkerboard or fallback texture staging before the final claim.

- [ ] **Step 4: Run tests to verify it passes** — `zig build test-ps4mode` → PASS; `zig build test` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/ps4_mode/gcn_translate.zig src/vulkan/backend.zig src/ps4_mode/gcn_real_blob_test.zig
git commit -m "feat(ps4): bind each draw's own GCN texture resource"
```

---

### Task 6: Correctness gate and live first-frame proof

**Files:**
- Modify: `src/ps4_mode/terraria_frame_test.zig` (extend existing hermetic fixture test)
- No source behavior changes except removing any leftover diagnostic prints.

**Interfaces:**
- Consumes: all public APIs from Tasks 1-5 plus the existing backend capture (`out/first-frame.ppm` via `PS5_CAPTURE_FIRST_FRAME=1`).

- [ ] **Step 1: Write the failing correctness test**

Add to `terraria_frame_test.zig`:
```zig
test "Terraria first frame uses guest geometry, UV and per-draw textures" {
    const cap = capture(&real_terraria_dcb);
    try std.testing.expectEqual(@as(usize, 2), cap.count);
    try std.testing.expect(translatedGraphicsFor(program) != null);
    try std.testing.expect(fragmentInputsFor(program).?.allocated != 0);
    try std.testing.expect(vertexDataSourceFor(cap.draws[0]) != null);
    try std.testing.expect(sampledImageUserIndexFor(program) != null);
    // Two draws must select two different PS T# addresses.
    try std.testing.expect(selectedTexture(cap.draws[0]) != selectedTexture(cap.draws[1]));
}
```
`selectedTexture(res)` is a small helper in the test file: take `sampledImageUserIndexFor(program)`, read that USER_DATA word pair from `res.userData(.pixel)`, and form the 40-bit address as in `gcn_resources.capture`.
This test fails on the current tree because `capture` has no per-draw snapshots (Task 1) and the remaining APIs do not exist.

- [ ] **Step 2: Run it to verify it fails** — `zig build test-ps4mode`.

- [ ] **Step 3: Confirm it passes after Tasks 1-5** — `zig build test-ps4mode` → PASS; `zig build test` → exit 0.

- [ ] **Step 4: Live first-frame verification (three runs)**

For each of three runs:
```bash
cd /home/reng/projects/ps5_zig_emu/PS5PCEM_PS4Mode
rm -f out/first-frame.ppm
PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 \
  timeout -s TERM 25 ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin \
  > /tmp/opencode/first-frame-run-N.log 2>&1
convert out/first-frame.ppm -colors 16 -format '%c' histogram:info:- | sort -rn | head
```
Expected per run: exit 124 (timeout is normal), `out/first-frame.ppm` exists, and the histogram has **at least 8 distinct colors with >= 100 pixels each** and **no single color covering > 90% of non-black pixels** (the current probe frame has one color covering ~99.9% of non-black pixels and must fail this gate). Record the exact histograms.

Also capture the live window:
```bash
DISPLAY=:0.0 xdotool search --name 'Vulkan guest output' | head -1
DISPLAY=:0.0 import -window <window-id> /tmp/opencode/correct-first-frame.png
```
Confirm the window is mapped (`xprop -id <id> _NET_WM_STATE` must not contain `HIDDEN`).

- [ ] **Step 5: Commit**

```bash
git add src/ps4_mode/terraria_frame_test.zig
git commit -m "test(ps4): gate Terraria's first frame on guest-sourced pixels"
```

## Final verification before declaring success

- `zig build test` → exit 0, all steps green.
- `zig build test-ps4mode` → PASS including the new gate.
- Three live runs produce materially the same multi-colored first frame.
- Native PS5 tests (byte-identity / gate tests) remain green.
- If any gate fails, report the exact log/histogram and do not claim the frame is correct.
