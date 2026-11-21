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

