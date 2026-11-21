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

