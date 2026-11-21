### Task 2: Wire the PS4 hook into game_run

**Files:** Modify `src/game_run.zig`; if needed, `src/ps4_mode/game_hook.zig`. Test: `zig build test-ps4mode`.

**Interfaces:** Consumes `ps4_mode.game_hook.decideForBlobs`, `configFromEnv`, `startupLine`, `runtime.Config.enabledFor`; `ps4_mode.bridge.runBuffer` / `runDefaultState`. Produces: when PS4 mode is active, the runner bootstraps a `runtime.Session` and lowers the driver default-state preamble into the shared GPU path.

- [ ] **Step 1:** Write a test in `src/ps4_mode/game_hook.zig` asserting `configFromEnv()` with `PS5_PS4_MODE=on` yields `enabledFor(.ps4_gnm) == true`, and without the variable it follows auto policy. Run `zig build test-ps4mode` and watch it fail.
- [ ] **Step 2:** In `src/game_run.zig`, read `PS5_PS4_MODE` once via `configFromEnv()`, call `decideForBlobs(param_sfo_bytes, eboot_bytes)`, print `startupLine`, and when `enabledFor(mode)` is true bootstrap the session and call `bridge.runDefaultState` with caller-owned scratch buffers. No changes inside the PS5 branch.
- [ ] **Step 3:** Run `zig build test-ps4mode` and full `zig build test`; expect PASS with no PS5 regressions.
- [ ] **Step 4:** Commit only those two files: `git commit -m "feat(ps4_mode): wire PS4-only hook into game_run"`.

