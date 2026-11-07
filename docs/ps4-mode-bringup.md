# DRIVECLUB (CUSA00003) Bring-up Log

Author: kleinergoo7. Game: DRIVECLUB, TITLE_ID CUSA00003, APP_VER 01.28.
Branch: `ps4-mode`. Toolchain: Zig 0.16.0 (`/home/reng/tools/`; host 0.17
cannot build this repo).

## Proven milestones

1. **Detection**: TITLE_ID `CUSA…` → `ps4_gnm` even though the inner ELF
   `e_type` is `0xFE10` (PS5 value). The `detector.decide` TITLE_ID-wins rule
   exists for exactly this re-wrapped case.
2. **Loading**: legacy-SELF eboot + 8 PRXs (libc, Fios2, libtbb, logiWheel,
   iksemelGNMm, oskGNMm, libfmod, libfmodstudio) parse via existing SELF/ELF.
3. **Linking**: 4571/4571 eboot imports resolve (571 generated stubs: 553 func
   success-stubs + 18 zeroed objects; real HLE covers the rest, incl. real
   pthread/mutex/direct-memory). Loader accepts PS4 otypes `0xFE00/0xFE01`
   and TLS-variant relocations against non-TLS symbols (defined-local,
   import-resolve, zero-quirk fallbacks).
4. **Execution**: guest runs static init → bootstrap, faults in PS4 libc
   `memset` (`libc.prx+0x30018`, NID `8zTFvBIAIN8`): `memset(rbx+0x20, 0,
   0x200)` with `rbx=0xd8`, target `0xf8` unmapped. Only 2 firmware calls
   precede it (`__cxa_guard_acquire/release`); the heap is never touched.

## Fault signature (stable across runs)

- `rip 0x8001fc008`, `rdi=0xf8 rbx=0xd8 rcx=0x40 rdx=0 r8=0x200`
- True return chain (rbp-walked, stale scan entries excluded): static init
  → `0x8242ee`-region ctor (`lea rdi,[rbx+0x20]; xor esi; mov edx,0x200;
  call memset`). Verified authoritative bytes via
  `module-info --bytes` (see below).
- The `0x8242f6` caller is reached with `rbx=0xd8`; origin unknown.

## Lessons for the next session

- **Bias varies per segment**: NEVER compute file offsets as
  `vaddr - 0x34d90` outside the one verified region. The RX segment is split
  across container segments. Always read guest code with
  `module-info --bytes <vaddr> <len>` (loader-authoritative). A whole
  disassembly walk (0x6bxxxx/0x823xxx frames) was invalidated by this.
- **Split stdout/stderr, then pipe through `cat`**: concurrent threads
  sharing one redirected fd clobber each other's bytes (heads eaten:
  `[link] no resolver for g…` → `eneral rela…`). `2>&1 | cat` gives atomic
  pipe writes and intact logs. `graph-info` cannot run here
  (`AddressSpaceUnavailable`); use `game-run` for link tests.
- **`--names` recovers semantics**: feed candidate symbol names to map
  NIDs (found: malloc `gQX+4GDQjpM`, calloc, memalign, free `tIhsqj0qsFE`,
  mspace pair, fopen `xeYO4u7uyJ0`, pthread_* → real libScePosix).
- **Link diagnostics are tagged**: `<<NODE>>`, `<<APPLY>>`, `<<NOIMPORT>>`,
  `<<NOIMPORT-TLSCOMPAT(-ZERO)>>`, `<<NULLRESOLVER>>`, `<<UNRESOLVABLE(-TLS)>>`
  in `loader/linker.zig` + `module_graph.zig`. Keep until bring-up lands.

## Prime hypotheses (unverified)

1. `rbx=0xd8` = NULL base + `0xd8` subobject LEA (no fault until first
   deref = the memset). Source: a stubbed factory/file call returning 0 —
   but no firmware calls precede the fault, so the NULL must come from
   static/BSS data or a zeroed TLS-quirk relocation (`NOIMPORT-TLSCOMPAT-ZERO`
   fires ~15× in libc.prx, `0xb84xx`, sym 1).
2. The `0x8242dc`-region function takes `this` in rdi from static init;
   find its entry (scan back from `0x8242ee` with `--bytes`) and xref it
   (`--rip-xrefs`) to identify the NULL source.
3. Next real subsystems by value: fopen/fread/fseek/fclose family (bootstrap
   reads streams; `fopen` still a zero-stub), then GNM submit/flip path.

## Repro

```
zig build install
./zig-out/bin/game-run --app0 /home/reng/disk/roms/ps4/CUSA00003 \
  /home/reng/disk/roms/ps4/CUSA00003/eboot.bin 2>&1 | cat > boot.log
./zig-out/bin/module-info <eboot> [--names names.txt] [--bytes VA LEN]
```

## Session: 2026-11-07 (root-cause hunt, this=0xd8)

### Verified facts

- **Fault reproduced exactly**: same rip (`libc.prx+0x30018`), same regs
  (`rbx=0xd8 rdi=0xf8`), 2 firmware calls (cxa pair), heap never called
  (0 `ps4heap` lines with instrumentation present in the binary).
- **DTPMOD-SELF fix is NOT the crash cause** (negative result): all 17
  `dtpmod64`-vs-section sites now emit real ids (eboot tm=2, libc tm=3,
  logged as `<<DTPMOD-SELF>>`), fault byte-identical afterwards. Correct
  fix regardless (module 0 was wrong), but the hunt continues elsewhere.
- **Null-object chain reconstructed from the recovery log** (previously
  unexamined; present in every run): stores to `0x70/0x78/0x88/0x90/0x98/
  0xa0` with `rdi=0x70` (all dropped by null-store emulation), one load
  from `0xd0`, `r15=0xd8` throughout. Shape: NULL base → `+0x70` object
  (fields built, silently dropped) → `+0x68` subobject (`r15=0xd8`) →
  `memset(0xd8+0x20)` = first real deref = the crash.
- **Bias varies per segment, proven twice**: vaddr `0x8242f6` ↔ file
  `0x7ef566` (bias `0x34d90`) vs vaddr `0x823bd0` ↔ file `0x82ee40`
  (bias `-0xb270`). An entire disassembly walk was invalidated by this.
  Only `module-info --bytes` (loader-authoritative) is trustworthy.
- **Log fd race, proven**: concurrent threads sharing one redirected fd
  eat each other's bytes (`[link] no resolver for g…` → `eneral rela…`).
  Always `2>&1 | cat` (atomic pipe writes).
- **F@0x824270 entry verified** (authoritative bytes): `rbx=rdi`
  confirmed; `r15d=esi&7` dispatch; stack-canary via global `0x166e250`.
  `--rip-xrefs` has false positives from zero padding (fields `0x82426b/c`
  are nop-fill rel32 0). Its caller is still unknown.
- **Bootstrap context**: nearby strings `x_events.prelobby`,
  `eSlotAlertFetchEGSData` — the game is initializing its event-stream
  subsystem (online content; NP/Http all stubbed) when it dies.
- **Recovery-log reporting conventions** (cpu/root.zig): `rip` = raw fault
  context; `caller`/`frame` = `stack[1]`/`stack[0]`; null-base redirect
  only fires for base reg `== 0` (our crash base `rbx=0xd8` bypasses it);
  null stores are emulated-as-dropped, which is why the `0x70`-object
  build leaves no trace except these lines.

### Test status

- `ps4_mode`: 20/20 green (`zig build test-ps4mode`).
- `loader`: 64/64 green incl. new regression test
  (`dtpmod64 against a local section symbol emits our TLS module id`,
  id 7 → writes 7).
- Full `zig build test`: 1999/2027 pass, 1 fail — the failure set is
  flaky parallel-execution noise (fixed guest-VA mappings colliding
  across concurrently running test binaries): **every** failing binary
  passes in isolation (exit 0), including loader/cpu/d3d12/gpu suites.
  Pre-existing infra behavior, unrelated to this change.

### Next step (narrow)

Find F@`0x824270`'s caller and the NULL source feeding `rdi`. rbx is
`rdi` at entry (verified) and nothing reassigns it before the faulting
 lea — so the caller passed `0xd8` (or a NULL its `+0xd8` LEA produced;
  check both). Candidate order per brief: (a) unrelocated data slot feeding
  the caller — RELATIVE/GLOB_DAT coverage vs PS4 tables; (b) per-segment
  bias in whatever produced the caller's pointer; (c) init order vs TLS;
  (d) firmware-filled pointer — DISFAVORED (zero firmware calls observed).

## Session: 2026-11-07 (root cause FOUND + fixed; new blocker)

### Root cause of this=0xd8 — PROVEN end to end (GDB at every level)

1. Static init → grandcaller (abs `0x6B83Ax`) → **guard** (abs `0x82ADE0`,
   verified `rdi=0x5a0`, ret `0x6b83af`) with hook slot
   (abs `0x278C4C0`) reading **0** (BSS, no relocation targets it).
2. Hook NULL → default path (verified hit at guard+`0x2c`) → PLT186
   (abs `0x127FBC0`, verified target) → eboot GOT → **libc.prx PLT**
   (abs `0x8001EB850`) → ITS GOT (`0x800286190`) → libc malloc
   (abs `0x8001EBC20`) → internal allocator (`0x8001EC500`).
   (Resolution order puts guest libc.prx exports ahead of HLE.)
3. libc malloc is dlmalloc-style over a **static default mspace**
   (abs `0x80028B788`) that is all zeros: magic check passes vacuously,
   flags (`+0x370`) lack bit `0x10` → smallbin path over empty bins →
   returns NULL. NOT an init-ordering accident in our loader: libc.prx
   genuinely declares **zero initializers** (empty INIT_ARRAY,
   `DT_INIT_ARRAY=0xbecc0/DT_INIT_ARRAYSZ=0`), and a hardware watchpoint
   on the flags field **never fires** — nothing ever initializes it.
   It needs firmware-free pure-guest state that simply isn't there.
4. `r14=NULL` → `init(NULL)` → caller (abs `0x823B90`, verified
   `rdi=0x0`) → `[0]=r12` dropped (recovery #1) → `r13=0x70`,
   `r15=0xd8` (pure LEA) → ctor (abs `0x82B160`, verified disassembly:
   installs vtable `0x1635470`, twiddles flags) stores dropped (#3–#8)
   → `memset(0xd8+0x20=0xf8)` hard-faults (`rep stos` unrecoverable).

### Fix (verified working)

- `preferHleImportId` now routes 7 allocator NIDs (malloc, calloc,
  memalign, free, realloc, mspaceMalloc, mspaceFree) to the emulated
  heap ahead of guest exports. No other HLE claims these NIDs, so PS5
  titles are unaffected (previously unresolvable there).
- `ps4_heap`: added `realloc`; arena mapping needs flags=`0`
  (`0x1000` is rejected with `EINVAL=0x80020016`, measured).
- Measured: `malloc(0x5a0)=0x200000010`, `malloc(0x8)=0x2000005c0`;
  boot passes the old fault into module loading (`LoadStartModule`
  works) and the bootstrap-heap phase.

### New blocker (unproven cause)

`std::bad_alloc` thrown during bootstrap (after `Unheaped allocation -
Using BootstrapHeap` + libtbb load), then a host crash (core dump).
Candidates: stubbed file I/O starving bootstrap (milestone 2), or the
next allocator gap (operator new resolves to libc.prx guest; its NIDs
didn't match Itanium candidates — needs more `--names` work).
Next: catch the throw site (guest `__cxa_throw`) and identify the
failing request before building file I/O.

### Method notes

- GDB beats static RE here: `nm` finds Zig host symbols
  (`libs.cxx_abi.cxaGuardAcquire`) as post-mapping anchors; guest
  absolute breakpoints work after mapping; `-ex` MUST precede `--args`.
- Absence-of-call is provable: unconditional logging in our heap
  (zero hits = never called) + trace ring totals (`of 2`).
- The `code=` field added to null-store recovery lines (cpu/root.zig)
  resolves addressing disputes empirically: pattern-search the bytes.
