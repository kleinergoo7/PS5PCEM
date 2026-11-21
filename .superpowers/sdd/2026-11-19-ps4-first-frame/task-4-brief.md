### Task 4: Close Terraria's PS4 imports

**Files:** Modify `src/hle/libs/ps4_title_stubs.zig` and/or a new PS4 wrapper module registered from `src/hle/root.zig`.

**Interfaces:** Consumes Task 1's Terraria MISS list and Task 3's `hits.record`. Produces: zero unresolved imports for Terraria.

- [ ] **Step 1:** For each MISS NID, classify per spec: void/idempotent → benign stub; value-returning → plausible value; allocation/sync/data → wrapper to shared implementation; no shared counterpart → minimal PS4 logic. Record the classification in the task report.
- [ ] **Step 2:** Register the NIDs via `id_override` in PS4-only tables; each new entry calls `hits.record`. Do not modify any PS5 export.
- [ ] **Step 3:** Build and run `PS5_PS4_MODE=on game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin`; expect no `unresolved` lines. Run full `zig build test`.
- [ ] **Step 4:** Commit only PS4 files: `git commit -m "feat(ps4): close Terraria import closure"`.

