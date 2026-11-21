# Task 2 report — Wire the PS4 hook into game_run

**Status:** DONE_WITH_CONCERNS

## Files touched
- `src/game_run.zig`
- `src/ps4_mode/game_hook.zig`

No other source, build, or HLE/loader/renderer file was changed. No subagents dispatched.

## RED → GREEN evidence

**RED (Step 1).** Added a test in `game_hook.zig` calling `configFromEnv()` for the
`PS5_PS4_MODE=on` and unset cases, then ran:

    zig build test-ps4mode

Result (exit 1):

    src/ps4_mode/game_hook.zig:48:5: error: use of undeclared identifier 'seedEnvConfig'

Calling `configFromEnv()` also exposed the latent `std.posix.getenv` error in
`src/ps4_mode/runtime.zig:53`: that API was removed in Zig 0.16 and had never
been analyzed because no test or call site referenced the function.

**GREEN (Steps 2–3).** Replaced the broken `configFromEnv` re-export with a
working implementation in `game_hook.zig` (no-arg signature preserved), added
the test, and wired `game_run.zig`. `zig build test-ps4mode` then reported:

    Build Summary: 3/3 steps succeeded; 21/21 tests passed (20 baseline + 1 new)

## What was implemented

`src/ps4_mode/game_hook.zig`
- `configFromEnv()` now returns a once-per-process config seeded by the runner.
  Zig 0.16 has no global `getenv`, and the no-libc `test-ps4mode` binary cannot
  call `std.c.getenv`, so the value is seeded via a new `seedEnvConfig()` helper
  that reads the env-derived policy/diag strings and stores a `runtime.Config`.
- New test covers both required cases: `on` enables compat for `.ps4_gnm` (and
  `.ps5_native` under forced policy), unset yields `auto` policy (PS4 on,
  PS5 off).
- `decideForBlobs`, `configFrom`, `startupLine`, and `env_mode`/`env_diag` are
  unchanged.

`src/game_run.zig`
- Imports `ps4_mode/root.zig` directly (no build.zig change needed).
- `readPs4Blobs()` reads only the `sce_sys/param.sfo` and eboot prefixes into
  caller-owned stack buffers, for directory and `.zar` inputs.
- After the /app0 mount is opened, the hook resolves env once
  (`seedEnvConfig` + `configFromEnv`), classifies the blobs with
  `decideForBlobs`, and — only when `enabledFor(mode)` — prints `startupLine`,
  bootstraps a `runtime.Session` via `bridge.runBuffer`, and calls
  `bridge.runDefaultState` with caller-owned scratch buffers.
- No edits inside the PS5 branch; the startup line and session work are gated
  on compat being active, so inactive/PS5 runs keep identical stdout.

## Verification

- `zig build build-game-run`: PASS (10/10 steps); game-run binary rebuilt.
- `zig build test-ps4mode`: PASS (21/21 tests; 1 newly added).
- `zig build test` (full): PASS — `62/62 steps succeeded; 2060/2091 tests
  passed (31 skipped)`. The 10 `failed command:` log lines are diagnostic text
  from tests that intentionally exercise failure paths; the step exit is 0.
- Functional smoke: `PS5_PS4_MODE=on game-run --app0 /tmp/opencode/verify-b
  .../eboot.bin` printed `[ps4_mode] mode=ps4-gnm compat=active`. With
  `PS5_PS4_MODE=off`, no `[ps4_mode]` line was printed.
- All commands used `/home/reng/tools/zig-x86_64-linux-0.16.0/zig` with
  `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`.

## Concerns

1. **Latent bug left in `runtime.zig` (out of scope).** `runtime.configFromEnv()`
   still calls `std.posix.getenv`, which does not exist in Zig 0.16. It is now
   unreferenced, so it stays dormant; any future direct caller will get a
   compile error. Fixing it would require editing a file outside the two-file
   allowlist.
2. **New helper `seedEnvConfig()`.** The brief's interface lists a no-arg
   `configFromEnv()`; that signature is preserved, but the runner must now seed
   the cached value from `init.minimal.environ` before calling it. This is the
   smallest libc-free way to make env config work on Zig 0.16.
3. **Preamble output is intentionally unconsumed for now.** `runDefaultState`
   fills caller-owned scratch buffers; no GPU executor consumes them until the
   later first-frame tasks, as scoped by the brief.
4. The startup line is printed only when compat is active (not unconditionally),
   chosen to honor "no PS5 behaviour change when PS4 mode is inactive."

## Commit

Single commit with only the two allowed files:
`feat(ps4_mode): wire PS4-only hook into game_run`
