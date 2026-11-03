# PS5PCEM: agent rules

## 0. Project facts

- Language/toolchain: Zig 0.16.0, always `/usr/bin/zig` (PATH `zig` is 0.17 and breaks builds).
- Build: `zig build build-game-run` (game binary); full `zig build`.
- Test: `zig build test`. Gate suite baseline: 1950 passed / 26 skipped / 0 failed.
- Format: `zig fmt .` before every build after a change.
- Release: `zig build -Doptimize=ReleaseSafe` (game-run ships ReleaseSafe).
- Fixture: none via env. Game runs use the `.zar` dump only, never an extracted
  folder: `/mnt/a4e320ca-02b3-4f27-8c0d-be9abe9fe67d/roms/ps5/Demons_Souls_PPSA01341-EUR-v01.007.000_ZAR.zar`.
  Never add game files, firmware, or keys to the repo.

## 1. Build and verify

- Decide success from the process exit status, never from grepping tool output.
  Messages can be localized (`Fehler:` vs `error:`); a grep can report zero
  errors on a failed build.
- After a build that can fail, confirm the artifact actually changed (mtime or
  hash). A stale artifact reads exactly like a successful build.
- After every change run `zig fmt .`, `zig build`, `zig build test`.
  Don't say "done" until all pass; state what was run and its output.
- Distribution binaries come from the release build.
- If a new native or third-party dependency is added, say so in the change.

## 2. Toolchain (Zig 0.16.0)

- Never write std APIs from memory. Check the installed std source
  (`zig env` -> `.std_dir`) first. Training data is mostly pre-0.16.
- 0.16: I/O needs an `std.Io` instance; containers are unmanaged (pass the
  allocator per call); `@Type` is gone; use `addTranslateC` instead of `@cImport`.

## 3. Emulator correctness

- Fixed-width ints (`u8`..`u64`) for guest values and anything read from a
  file, never `usize`.
- Use wrapping ops (`+%`, `-%`, `*%`) where hardware wraps. Check arithmetic on
  file-controlled values for overflow before use in sizes, offsets, allocations.
- Hardware layouts: `extern`/`packed struct` plus comptime size assertions.
- Guest addresses and host pointers are different types.
- Comment every `@intCast`/`@ptrCast`/`@bitCast` with why it's safe (name the
  bounds check that makes it valid). Required in new/changed code. Existing
  uncommented casts are known debt; don't mass-fix them unless asked.
- Guest input is untrusted: bounds-check it, report faults via the project's
  diagnostics, never panic or crash the host. Truncated input is the normal
  failure mode, not an edge case.
- Never mask bugs to make a title progress: no speculative commits, silent
  fallbacks, or auto-retries that hide a failure. Every guest-visible failure
  must surface through the project's diagnostics at the point it occurs.
  A workaround is labelled `WORKAROUND`, states why, and logs every trigger.
  Silent workarounds are bugs.

## 4. Memory and errors

- No hidden allocation: take `std.mem.Allocator`; put `defer`/`errdefer` on the next line.
- No allocating, logging, or formatting in hot paths (CPU loop, command decode).
- Inferred error sets (`!T`) are fine for internal code, matching the repo.
  Use explicit error sets only for public module APIs. Never `anyerror`.
- No `catch unreachable`/`@panic` for guest-triggerable cases.
- No empty catches, no swallowed errors, no default that hides a failure.
  Every failure returns a named error plus a message naming what failed and on
  which input. Refusals carry kind, file, field, and a user-facing sentence.
- No partial output survives a failure; temp files die on error paths.

## 5. Tests

- `test` blocks beside the code, using `std.testing.allocator`. Every function
  with a branch, loop, parser, or arithmetic on file data gets a test, covering
  bad input, edge cases, and the failure side of every refusal. Test names
  state the behavior.
- Assert concrete values (magic bytes, counts, totals, hashes), not truthiness.
- Tests use synthetic in-tree fixtures and never touch the game archive.
- Respect module boundaries from docs/architecture/ (e.g. cpu never imports vulkan).

## 6. Streaming and disk

- Never materialize a large extracted artifact in full. Stream entry by entry;
  the `.zar` dump streams read-only without extracting.
- Cap any disk spill and abort before filling the disk. Open inputs read-only.

## 7. Style

- Types PascalCase, functions camelCase, everything else snake_case.
- Short functions, early returns, no deep nesting. No magic numbers.
- Comments explain WHY (cite the spec or docs/architecture/), not what.
- Wrap each C library (Vulkan, FFmpeg, HID) in one Zig module; convert C errors
  and pointers at the boundary. Every object has an owner and a `deinit` in
  reverse creation order.
- Small focused diffs, no unrelated churn, no new dependencies without asking.
- Match the surrounding style.

## 8. Git hygiene

- Small commits, one reason each. Build fixes and behavior fixes land separately.
- Never force-push, never rewrite history without a backup branch.

## 9. Session rules

- Game runs always use the `.zar` archive dump, never the extracted folder
  (faster): `/mnt/a4e320ca-02b3-4f27-8c0d-be9abe9fe67d/roms/ps5/Demons_Souls_PPSA01341-EUR-v01.007.000_ZAR.zar`.
- Pin runs: `taskset -c 0-3,8-11`, max `-j8`, `nice -n 5`, one build/run at a time.
- Keep the tree clean; no game files in the repo. Diagnostics opt-in, never
  always on. Reference emulators are observation only, no code copying.

## 10. When unsure

- If you can't verify an API or the requirement is unclear, say so and ask.
- Prefer refusing an input over producing output that may be wrong.
