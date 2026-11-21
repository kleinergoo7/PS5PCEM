# Terraria first-frame attempt — investigation/fix log

**Task:** make Terraria render its first guest frame in PS5PCEM, working in the
isolated worktree `/home/reng/projects/ps5_zig_emu/.worktrees/terraria-frame`
(branch `terraria-first-frame`).

**Status: BLOCKED** — the original crash is fixed and Terraria now executes
guest code past allocator init, but it does not submit a draw-bearing command
buffer, so no `out/first-frame.ppm` is ever produced. The remaining wall is a
shared GPU-pipeline limitation (PS4 GCN PM4 → RDNA2 PM4 translation), not a PS4
wrapper.

## Environment / commands

- Zig: `/home/reng/tools/zig-x86_64-linux-0.16.0/zig`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`
- Build: `zig build build-game-run`
- Run (success criterion):
  `PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 ./zig-out/bin/game-run --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin`
  (verification runs wrapped in `timeout N`, see below)

## Wall 1 — heap `incorrect alignment` panic (FIXED)

Baseline (commit `43af013`) exited 134 with:

```
thread ... panic: incorrect alignment
src/hle/libs/ps4_heap.zig:98 in insertFreeLocked
  setNext(prev, block)
```

### Diagnosis

Instrumented `insertFreeLocked` to dump any free-list entry whose address was
not 16-byte aligned. The first corrupt entry was `0x20b6ffd54`, which persisted
as the head of the free list once corruption started. Root cause: in
`insertFreeLocked`, the **merge-with-prev** branch extended `prev`'s header to
absorb `block` but never updated `prev->next`. The absorbed node stayed linked
in the free list as a ghost; once the merged region was handed to the guest,
guest writes overran the ghost's `next` pointer with garbage. Traversing that
garbage produced a misaligned `prev`, and `setNext(prev, block)` panicked.

### Fix (commit `cd12431`)

`src/hle/libs/ps4_heap.zig` — after absorbing `block` into `prev`, set
`setNext(prev, cur)` so the ghost node is unlinked. PS4-only file; no PS5
allocator/HLE touched.

### Result

The panic is gone. With the exact run command the process now executes guest
code until the harness timeout (verified with timeouts of 75s, 90s, 240s and
600s — all produce the same ~4580-line log and the same final allocation
address `0x20ecc9240`). No `out/first-frame.ppm`.

## Wall 2 — PS4 GNM submit is a no-op (FIXED at the PS4 boundary)

Tracing with `PS5_GNM_DIAG=1 PS5_TRACE=<all 26 GNM NIDs>` showed exactly three
low-frequency GNM-driver NIDs (`QhnyReteJ1M`, `W1Etj-jlW7Y`, `7qZVNgEu+SY`,
all init/config) and one real submit:

```
[call ] t5 sceGnmSubmitAndFlipCommandBuffers(0x1, 0x7e0227e90, 0xe0227e8c, 0x0) caller=0x3e5434
```

`sceGnmSubmitAndFlipCommandBuffers` in `src/hle/libs/gnm_compat.zig` was a
bare `return errno.ok`, so Terraria's only command-buffer submission never
reached any GPU path.

A temporary 6-argument diagnostic wrapper recovered the true PS4 signature and
descriptor:

```
[gnm diag] dcb_count=1 addrs=0x7e0227e90 sizes=0x7e0227e8c flip_count=0 ...
[gnm diag] dcb[0] addr=0x100000034c size=0xc58 words=790
[gnm diag] first words: 0xc0055800 0x88c40000 0x1 0x0
```

`0xc0055800` is a standard PM4 type-3 header (top bits `0b11`), confirming PS4
GNM emits GCN-era PM4 that the shared `gpu.pm4` walker can parse.

### Fix (commit `165127f`)

`src/hle/libs/gnm_compat.zig` — decode the PS4 `{dcb_gpu_addrs[], dcb_sizes[]}`
descriptors and hand each guest DCB slice to the shared
`agc_submit.submitDeviceStream`. The PS4 wrapper only decodes the PS4-specific
descriptor; all packet parsing/lowering/execution stays in the shared path.
Also wired `ps4_mode.hits.report()` into `hits.record` (every 25k records,
gated by `PS5_GNM_DIAG`) so the PS4 wrapper hit table is observable as the plan
requires. No PS5 export, loader or renderer changed.

### Result

The submit now reaches the shared executor, producing:

```
[dcb] 0x100000034c 790 dwords
  00000: ACQUIRE_MEM 6 dwords
  00007: SET_CONTEXT_REG context[0xa205] x1
  00010: SET_CONTEXT_REG context[0xa2df] x1
  00013: SET_CONTEXT_REG context[0x10900] x1
  00016: <Truncated at 0x10100a00, 774 words remain>
  packets 4, draws 0, dispatches 0
[dcb] trimmed trailing allocation data: 16/790 dwords @0x100000034c
[gpu executor] packet rejected depth=0 word=13/16 header=0xc0016900
               op=SET_CONTEXT_REG: RegisterOutOfRange
[dcb] queue stopped: RegisterOutOfRange
```

## Wall 3 — no draw-bearing DCB; shared GCN→RDNA2 translation missing (BLOCKER)

Evidence gathered from `PS5_TRACE=1` full traces:

- The only GNM submit is a pure setup DCB. A full type-3 PM4 header scan of all
  790 dwords found exactly: 33 `SET_CONTEXT_REG` (op `0x69`), 1 `ACQUIRE_MEM`
  (op `0x58`), 1 op `0x10` — **zero draws and zero dispatches**. Its
  `context[0x10900]` register write is a GCN register offset that the shared
  RDNA2 executor rejects as `RegisterOutOfRange`, stopping the graphics queue.
- After the submit, the game's main threads stop calling HLE entirely
  (t1 last at trace seq 31330, t5 last at 31366, t6 drains its semaphore queue
  until 61257). Only audio/network polling threads keep running. The process
  spins until killed; the malloc count freezes at ~4580 with the same final
  address for every timeout.
- Rendering therefore never reaches the Vulkan backend's render-target
  materialization, so the `colored != 0` gate that writes `out/first-frame.ppm`
  is never satisfied. Confirmed: no PPM in the worktree (including the literal
  backslash filename `out\first-frame.ppm`).

To make progress, the PS4 GCN PM4 stream must be translated to RDNA2 PM4 the
shared executor accepts — remapping context-register offsets (e.g. `0x10900`)
and following/handling the indirect-buffer jump to `0x10100a00` that currently
truncates the walker. That work belongs in the shared `gpu/` PM4 state layer
(or a real GNM→RDNA2 lowering stage), not in a PS4 wrapper: there is no shared
counterpart to call, and adding one would change PS5 renderer code, which the
task forbids. The existing `ps4_mode/gnm_packets.zig` / `gpu_translate.zig`
stage emits neutral tagged items (`Lowered`), not executable PM4, so it cannot
feed the shared executor as-is.

This is the genuine shared-infrastructure blocker the plan's Task 6 Step 2
allows us to report.

## Commits on `terraria-first-frame`

1. `cd12431` `fix(ps4heap): unlink absorbed node on free-list merge`
2. `165127f` `feat(ps4): funnel GNM submit into shared AGC executor`

The temporary `gnm_compat.zig` diagnostic used for the Wall 3 DCB dump was
removed; the working tree is clean and matches commit `165127f`. The remaining
`[gnm submit] dcbs=... submitted=...` print is gated behind `trace.announces`,
so it is silent in a normal run.

## Final clean verification (tree == commit `165127f`)

Rebuilt from the clean tree and re-ran the exact command (wrapped in
`timeout 60`). Output:

```
BUILD_OK
EXIT=124
PPM:
NO_PPM
panic:
0
malloc lines:
4531
last malloc:
[ps4heap] malloc(0x8) = 0x20ecc9240
dcb:
[dcb] trimmed trailing allocation data: 16/790 dwords @0x100000034c
[dcb] queue stopped: RegisterOutOfRange
```

The alignment panic is gone (0 panics), but the guest stalls before any draw,
so no `out/first-frame.ppm` (size/pixel summary unavailable — the file does not
exist).

## Concerns / what was not checked

- Verified only with a 600s harness timeout; the no-submit and submit-wired
  runs freeze at the same guest point, so additional wall-clock time will not
  change the outcome.
- The full GCN→RDNA2 PM4 translation needed for Wall 3 was not implemented: it
  is renderer-level work outside the permitted PS4-wrapper scope.
- Full `zig build test` was not re-run after the final commits (the changes are
  confined to PS4-only files plus the PS4-mode hits module); worth running
  before merge.
