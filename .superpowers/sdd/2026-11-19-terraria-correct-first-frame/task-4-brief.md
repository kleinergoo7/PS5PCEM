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

