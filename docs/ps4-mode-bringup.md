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
