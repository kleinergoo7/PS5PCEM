# OneShot (CUSA34845) — `oneshot-continue` first-frame report

**Status: BLOCKED** — OneShot deterministically faults on a null `FILE*` while
loading an XNB asset, before any GNM submission. No `out/first-frame.ppm` is
produced. No PS5/shared code change is needed or justified; the failing path
contains **no PS4 boundary import that could be given a plausible value** —
the asset I/O is guest-internal. No source changes were kept, so **no commits**.

## Environment / exact command

- Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/oneshot-continue` (branch `oneshot-continue`, HEAD `542b940`)
- Zig: `/home/reng/tools/zig-x86_64-linux-0.16.0/zig`, `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`

```
cd /home/reng/projects/ps5_zig_emu/.worktrees/oneshot-continue && \
PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 \
timeout -s TERM 45 ./zig-out/bin/game-run \
  --app0 /tmp/opencode/verify-a /tmp/opencode/verify-a/eboot.bin
```

Final clean-tree result (identical across the 4 runs on this branch):

```
EXIT=1
PPM: NO_PPM
guest fault: access through a null pointer
  rip         0x0000000000054ee6 eboot.bin+0x14ee6
  target      0x0000000000000000 <unmapped>
  rax 0x...0  rbx 0x...0  rcx 0x...1000  rdx 0x...0
  rsi 0x0000001000176a80  rdi 0x0000000000000000
guest fault: access_violation/read, code=0xc0000005, dispatch=0x23bf500,
             rip=0x54ee6, address=0x0, rsp=0x7e0127770
SubmitAndFlip/DCB lines: 0
malloc lines: 30927
unresolved/cannot link: 0
```

## Diagnosis

### Faulting instruction and null value

gdb disassembly of the guest function (`eboot.bin+0x14ec0`, i.e. runtime `0x54ec0`):

```
0x54ec0: push rbp; mov rbp,rsp; sub rsp,0x40
0x54ec8: mov [rbp-0x10], rdi     ; arg1 = pointer-to-FILE*
0x54ee2: mov rax, [rbp-0x10]
0x54ee6: mov rax, [rax]          ; FAULT: arg1 == 0  (rax = 0)
0x54ee9: mov [rbp-0x38], rax
0x54eed: cmp qword [rbp-0x38], 0
0x54ef2: jne 0x54f12             ; non-null -> fread(ptr,1,count,FILE*)
```

This is a MonoGame stream wrapper around `fread`. Breakpoint at `0x54ec0`
(after `dispatchProcess` so guest memory was mapped) confirmed all args at
fault time: `rdi=0`, `rsi=0x1000176a80`, `rdx=0`, `rcx=0x1000`,
`r8=0x7e0127848`, return `0x2f8969`.

The HLE import thunk it calls (`0x23c9f80` -> GOT `0x3241718` ->
`0x80088fe60`) is `fread` in the guest's `scePlayStation4`/`libc` PRX range
(disassembled: `test rsi/rdx; mul size*count; ... FILE*+0x30 buffer ...`).
Sibling wrappers at `0x54e20`, `0x54f50`, `0x54ff0` deref the same style of
null slot and call `fclose`/`fwrite` (`0x80088eeb0`, `0x800890450`).

The null slot is `this->field_0x48` of a MonoGame object at
`this = 0x100008e1b0` (vtable `0x3530480`, in the 3.5 GB direct-memory window
the guest maps for graphics content). `this+0x28 = 0x1000176a80` is a
`0x1030`-byte read buffer that the guest memsets immediately before the fault
(firmware call 77203: `ps4-memset(0x1000176a80, 0, 0x1030)`). The object was
zeroed at allocation (firmware call 55616) and `field_0x48` was **never
written** — it is the missing `FILE*` from a failed content-file open.

### Root cause: content-file open fails inside guest PRX code

- Full `PS5_TRACE=1` run shows `[stat ] "/app0/Content/white16x16.xnb" -> ok`
  (firmware calls 77146 and 77189 — `sceKernelStat` **succeeds**).
- The host file exists: `/tmp/opencode/verify-a/Content/white16x16.xnb` (1109 bytes).
- A temporary diagnostic added after the `/app0` mount confirmed the shared
  HLE filesystem can open it: `[fsdiag] open white16x16 -> 3`.
- A temporary `OPENDIAG` print inside `sceKernelOpen` recorded **zero** calls
  for that path; there are also zero `[cpu] blocked guest system call` lines.
  So the failing `fopen` is implemented entirely inside the guest PRXs and
  never reaches any HLE file-open entry point we provide. Its failure is a
  guest-runtime issue, not a PS4 boundary value-returning import: all 111
  OneShot NIDs registered in `ps4_oneshot_stubs.zig` are status/idempotent
  calls (the prior agent's classification), and none is a libc file opener.
- The PRX's `fopen` (`0x80088f850`) calls an internal open routine
  (`0x8008996e0`) that has no `call 0x23c9fxx` / indirect call / syscall to
  HLE — confirming the I/O backend is guest-internal.

### Bypass experiment (gdb-only, reverted)

To prove what lies past the fault, I set conditional breakpoints at the four
sibling wrappers (`0x54e20`, `0x54ec0`, `0x54f50`, `0x54ff0`) once guest memory
was mapped and rewrote `rdi` to a zero-filled qword slot so each wrapper took
its "value == 0" branch and skipped the HLE call:

- Guest executed **75 s with zero contained faults**, firmware calls advanced
  from ~77 k to ~100 k.
- It threw a C++ exception: `Error: Invalid handle to path
  "/app0/Content/white16x16.xnb"` (firmware call 77489, `_write` from
  `libc.prx` at `0x8008b71e7`), with a full `sceKernelGetModuleInfoForUnwind`
  stack walk (53 frames) through the same MonoGame functions.
- Guest then stalled: malloc count frozen at 31053 (same at 20 s and 75 s).
- **Zero** `sceGnmSubmitAndFlipCommandBuffers` calls, **zero** `[dcb]` lines,
  **zero** PPM in all bypass runs.

This is the decisive evidence that the blocker is upstream of the renderer:
no guest draw-bearing command buffer is ever submitted.

## Verification performed (clean tree, HEAD 542b940)

- `zig build build-game-run` — exit 0
- `zig build test-ps4mode` — exit 0
- `zig build test` — exit 0 (the `failed command:` line is from a test
  binary's own diagnostic subprocess; overall step succeeds)
- Exact success command — exit 1, no frame, 0 unresolved imports, 0 PM4 submits

All temporary instrumentation (kernel_files `OPENDIAG`, game_run `fsdiag`,
gdb breakpoints) was reverted; `git status` is clean, **no commits made**.

## Concerns / what remains

1. The asset `fopen` backend lives in the shipped PS4 PRX code and is not
   routed through our HLE. Making it succeed requires either an HLE shim for
   the guest libc file-I/O backend (shared/HLE work, outside the permitted PS4
   boundary) or reverse-engineering and patching the PRX. Neither is a
   value-returning-import fix, so I did not implement one.
2. Even with the null derefs bypassed, no GNM submit occurs and the guest
   throws a content exception then stalls — so the Terraria-style
   render-target register synthesis at the submit boundary has nothing to
   act on. There are no draws to preserve.
3. The `[ps4heap] malloc` debug print is unconditional and fills ~31 k lines
   per run; this is inherited state, not changed here.
4. I did not decrypt/disassemble the full `scePlayStation4.prx`/`libc.prx`
   fopen call graph, nor patch guest code — both are outside the allowed
   PS4-boundary scope.

## Skipped / not checked

No PPM size or pixel summary exists: the file was never written. I did not
modify `src/gpu/**`, shared HLE implementations, or any PS5 path; no PS4
boundary file was changed either, because the diagnosis found no PS4 import
in the failing path to fix. The branch is left unchanged at `542b940`.

## Round 3 — libc shim landed, new wall: empty equeue wait

The PS4-keyed libc I/O exports (committed `1f631bb` + gating `a0bf6ad`) remove
the null-FILE* fault entirely: 0 guest faults, content loads, and the title now
submits 3 DCBs (546/283/352 words) through the shared AGC executor.

New measured wall: the guest parks in `sceKernelWaitEqueue(handle=1)` with
**zero registered events** (temporary diagnostic showed one `createEqueue` and
`active_regs=0 flip_regs=0`). It called `sceVideoOutOpen(0xff,...) = 1` and
`sceVideoOutSetFlipRate(1,0)`, but never `sceVideoOutAddFlipEvent`, never
`sceGnmAddEqEvent`, never a user-event add. All DCBs contain no draws
(`ignored=1: 0x47`) and `[agc completion] labels=0`. So the wait has no
producer: the title is blocked on an event it never registered (likely an
initialization path that expects a driver call we still stub out).

Diagnostics were fully reverted; branch is clean at `a0bf6ad`.
