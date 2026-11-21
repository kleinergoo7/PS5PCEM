### Task 3: PS4-only hit counters

**Files:** Create `src/ps4_mode/hits.zig`; modify `src/ps4_mode/root.zig`. Test in `src/ps4_mode/hits.zig`.

**Interfaces:** Produces: `record(name: []const u8)`, `report(buf: []u8) []const u8`, `reset()` — PS4-only counters gated by `PS5_GNM_DIAG`. Must not import or modify `src/hle/trace.zig`.

- [ ] **Step 1:** Write a test asserting two `record` calls for the same name produce a report containing that name and count 2, and that `reset()` clears it. Run `zig build test-ps4mode`; expect failure.
- [ ] **Step 2:** Implement the counters with fixed-size storage and report formatting in `src/ps4_mode/hits.zig`; export from `root.zig`.
- [ ] **Step 3:** Run `zig build test-ps4mode`; expect PASS. Confirm `git diff` touches no file under `src/hle/trace.zig`.
- [ ] **Step 4:** Commit: `git commit -m "feat(ps4_mode): add PS4-only wrapper hit counters"`.

