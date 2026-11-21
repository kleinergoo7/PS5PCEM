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

