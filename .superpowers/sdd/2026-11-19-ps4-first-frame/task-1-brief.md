### Task 1: Measure MISS imports for both ROMs

**Files:** create `.superpowers/sdd/2026-11-19-ps4-first-frame/miss-inventory.md` (plan workspace artifact, not committed).

**Interfaces:** Produces: per-ROM list of `{library, NID, kind}` for every unresolved import, plus the exact `game-run` link-failure lines.

- [ ] **Step 1:** Run `module-info` (`zig build module-info -- <file>`) on `/tmp/opencode/verify-b/eboot.bin` and every `sce_module/*.prx`, collect lines beginning `MISS`.
- [ ] **Step 2:** Repeat for `/tmp/opencode/verify-a/eboot.bin` and its `sce_module/*.prx`.
- [ ] **Step 3:** Record both lists with the exact command used for each and the link-failure output from `PS5_PS4_MODE=on game-run --app0 <tree> <eboot>`. Return the file path and a summary count. No source changes.

