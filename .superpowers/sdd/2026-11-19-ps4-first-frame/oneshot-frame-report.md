# OneShot (CUSA34845) — first-frame bring-up report

Subagent task: make OneShot render its first guest frame in PS5PCEM, working in the
isolated worktree `/home/reng/projects/ps5_zig_emu/.worktrees/oneshot-frame`
(branch `oneshot-first-frame`, base `95c20f6`).

## Status: BLOCKED — shared PS4 heap allocator corruption (free-list hang)

OneShot links cleanly and enters guest execution, but the guest main thread hangs
forever inside `src/hle/libs/ps4_heap.zig`'s free-list insertion. This is the same
shared PS4 allocator the parallel Terraria agent is fixing; per the binding task
rules I did **not** duplicate that fix. No `out/first-frame.ppm` is produced.

## Exact command and output (final committed state)

```
cd /home/reng/projects/ps5_zig_emu/.worktrees/oneshot-frame
PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 \
  timeout -s TERM 45 ./zig-out/bin/game-run \
  --app0 /tmp/opencode/verify-a /tmp/opencode/verify-a/eboot.bin
```

Result: `EXIT=124` (SIGTERM after 45 s — the guest loop does not self-terminate).

```
=== malloc count ===     30748        # [ps4heap] malloc lines
=== unresolved/cannot link ===  0     # import closure holds
=== last 6 lines ===
[ps4heap] malloc(0x20) = 0x20025e140
[ps4heap] malloc(0x20) = 0x20025e110
[ps4heap] malloc(0x20) = 0x20025e140
[ps4heap] malloc(0x8)  = 0x20025e110
[ps4heap] malloc(0x10) = 0x20025e130
[ps4heap] malloc(0x8)  = 0x20025e150
=== FRAME ===            NO FRAME     # out/first-frame.ppm absent
```

The 30 748-malloc count is deterministic: a 120 s run produced the **same** count
and the same final addresses. The guest stops allocating and spins with no further
HLE calls (no PS4 NID stub is ever reached — a periodic `ps4_mode.hits.report()`
probe, since removed, recorded zero wrapper calls).

## Precise blocker: guest thread wedged in `ps4_heap.insertFreeLocked`

`gdb -p <game-run pid>`, thread 1 (the guest bootstrap thread), on the final
committed binary:

```
libs.ps4_heap.insertFreeLocked (block=8592417152) at src/hle/libs/ps4_heap.zig:84
84      while (cur != 0 and cur < block) {
#0  insertFreeLocked (block=8592417152)   ps4_heap.zig:84
#1  allocLocked (size=<optimized out>, alignment=16) ps4_heap.zig:135
#2  mallocImpl (size=8)                   ps4_heap.zig:171
#3  host_stack.call__anon_302656.Invoker.invoke   host_stack.zig:306
#4  ps5HleCallOnStack ()
Backtrace stopped: Cannot access memory at address 0xfc00400020
```

`8592417152 == 0x2_0025_e140`, exactly the address in the last malloc log lines.
The loop at line 84 (`while (cur != 0 and cur < block) { prev = cur; cur =
getNext(cur); }`) never terminates because the free list is corrupt (a ghost /
cyclic node), so the next insertion walks it forever holding `heap_lock`.

### Root cause (confirmed by the parallel agent's commit)

Commit `cd12431 fix(ps4heap): unlink absorbed node on free-list merge` on branch
`terraria-first-frame` documents the exact defect: when `insertFreeLocked` merges
a new block into its previous neighbour it extends `prev`'s header but leaves
`prev->next` pointing at the absorbed node. That ghost node stays linked; once the
merged region is allocated the guest overwrites its `next` pointer, corrupting the
free list. For Terraria this produced an `incorrect alignment` panic at
`ps4_heap.zig:98`; for OneShot it produces the infinite loop at `ps4_heap.zig:84`.
Same file, same function, same root cause, same fix (`setNext(prev, cur)` on the
merge path).

### Proof the shared fix unblocks the hang (temporary experiment, reverted)

I temporarily copied the already-committed fixed `ps4_heap.zig` from the Terraria
worktree into this one, rebuilt, and ran the exact command. Result:

- The free-list hang is gone; malloc count rises to 30 927 and firmware calls to
  77 225 (vs 30 748 / ~77 k before the freeze).
- A *new* wall appears: a guest null-pointer read, `access_violation/read` at
  `rip=0x54ee6` (`eboot.bin+0x14ee6`), `rax=0x0`, target `0x0`. The last firmware
  calls before it are `sceKernelStat(...) = 0x0`, `__error()`, `ps4-memset(...)`,
  and `_sigprocmask`/mutex churn — no PS4 NID stub. Guest stack scan:
  `eboot.bin+0x4fa, +0x2b8968, +0x2b7d00, +0x2b88c1, +0x2b8766, +0x15f7, +0x6ec`.
- Still no `out/first-frame.ppm`.

The temporary file copies were **restored** (`git status` clean apart from the
committed capacity change below); the shared fix was not duplicated or committed
on this branch.

## Commits on this branch (beyond base `95c20f6`)

- `7ee5953 fix(ps4_mode): widen PS4 hit counters to 256 names` — one-line
  PS4-only capacity bump 128 → 256 (Terraria 37 + OneShot 111 = 148 distinct NIDs
  exceeded 128, so `PS5_GNM_DIAG` hit reports could drop names). Explicitly in
  scope per the brief. No PS5 path touched.

No other source changes remain on this branch; all diagnostic instrumentation
(periodic hit dump, 256-call fault trace, temporary shared fix) was reverted.

## Verification performed

- `zig build -p zig-out` (Zig 0.16.0, `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`): exit 0.
- `zig build test` (full suite): exit 0. Zig global cache stayed at 107 MB (well under the 5 GB cap).
- Exact success command: exit 124 via SIGTERM, 0 `unresolved`/`cannot link`, no frame.

## Concerns / next steps for the controller

1. **Integrate the shared fix first.** Cherry-pick / merge `cd12431` from
   `terraria-first-frame` into the integration branch; that removes the OneShot
   allocator hang. I did not do this here to avoid duplicating the parallel
   agent's work and to respect the "report and stop" instruction.
2. **Then diagnose the null-pointer wall** at `eboot.bin+0x14ee6` (details above).
   It is downstream of the shared fix and appears to be guest code dereferencing
   a null pointer after filesystem/stat + errno activity; it may need a PS4
   boundary stub returning a real value, or it may be a deeper guest-runtime
   issue. I did not fix it because the branch cannot reach it without the shared
   allocator fix.
3. The `[ps4heap] malloc` debug print in `mallocImpl` (`ps4_heap.zig:172`) is
   unconditional and dominates the log (~30 k lines/run); consider gating it by
   `PS5_GNM_DIAG` in the shared allocator work.
4. No PS5 file was modified. All work stayed in PS4-only modules (`ps4_mode/hits.zig`);
   temporary edits to shared files were reverted before the final build/test/commit.

## Skipped / not checked

I did not decode the SELF to reverse the guest code at `eboot.bin+0x14ee6`, and I
did not chase the post-shared-fix null deref to a specific stub — both are
downstream of a shared blocker the brief told me to stop at.
