### Task 5: Close OneShot's PS4 imports

**Files:** same PS4-only registration files as Task 4.

**Interfaces:** Consumes Task 1's OneShot MISS list and Task 4's registration pattern.

- [ ] **Step 1:** Classify and register OneShot's MISS NIDs, including the `libSceSysmodule` alias and `libSceCompanionUtil`, using the same PS4-only path.
- [ ] **Step 2:** Run the same `game-run` command against `/tmp/opencode/verify-a`; expect no `unresolved` lines. Run full `zig build test`.
- [ ] **Step 3:** Commit: `git commit -m "feat(ps4): close OneShot import closure"`.

