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
