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

