# PS4 first-frame — Task 1: MISS import inventory

Scope: read-only measurement of unresolved imports for both authoritative
extracted ROM trees. No source, index, HEAD or branch state was changed.

## Exact commands used

- `zig build module-info -- <file>` is **broken** in this checkout with the only
  installed toolchain (Zig 0.17.1): `build.zig:34:7: error: no field named
  'ReleaseSafe' in enum 'lang.Optimize'`. The prebuilt binary was used instead;
  it is the same tool (`src/module_info.zig`) built before the toolchain drift.
  - module-info invocation, per file:
    `cd /home/reng/projects/ps5_zig_emu/PS5PCEM_PS4Mode && ./zig-out/bin/module-info <file>`
  - link invocation, per ROM:
    `cd /home/reng/projects/ps5_zig_emu/PS5PCEM_PS4Mode && PS5_PS4_MODE=on ./zig-out/bin/game-run --app0 <tree> <tree>/eboot.bin`

## Conventions

- `module-info` import lines are formatted `  0xADDR  <STATUS> <NID>  <module>/<library>  <kind>  <reloc>`;
  an unresolved import carries the `MISS` status mark. "Lines beginning MISS"
  is read as "lines whose status field is MISS" (they physically begin with the
  address). Collection used `grep ' MISS '`.
- `{library, NID, kind}` = library name (after `/` in the printed `module/library`),
  the 11-char NID, and the symbol type (`func`/`object`/`tls`/...).
- Counts are MISS occurrences (one per import/relocation entry), not unique NIDs.

## ROM: verify-b  (/tmp/opencode/verify-b)

Per-module MISS counts (occurrences):

| module | MISS |
|---|---:|
| eboot.bin | 126 |
| sce_module/libc.prx | 0 |
| sce_module/libSceFios2.prx | 0 |
| **TOTAL** | **126** |

### eboot.bin — 126 MISS

| library | NID | kind |
|---|---|---|
| libc | 5PfqUBaQf4g | object |
| libSceCompanionUtil | IPN-FRSrafk | func |
| libSceCompanionUtil | xb1xlIhf0QY | func |
| libSceCompanionUtil | H1fYQd5lFAI | func |
| libSceCompanionUtil | cE5Msy11WhU | func |
| libSceNet | TCkRD0DWNLg | func |
| libSceInvitationDialog | 9+g9iOq+7kg | func |
| libSceInvitationDialog | 8XKR6wa64iQ | func |
| libSceInvitationDialog | B6HVJtDYxEE | func |
| libSceInvitationDialog | XvA5KS56wcs | func |
| libSceInvitationDialog | 0zU0G+wiVLA | func |
| libSceNpMatching2 | 10t3e5+JPnU | func |
| libSceNpCommon | sXVQUIGmk2U | func |
| libSceNpMatching2 | tHD5FPFXtu4 | func |
| libSceNpMatching2 | -f6M4caNe8k | func |
| libSceNpMatching2 | Nz-ZE7ur32I | func |
| libSceNpMatching2 | fQQfP87I7hs | func |
| libSceNpCommon | m9JzZSoDVFY | func |
| libSceNpMatching2 | YfmpW719rMo | func |
| libSceNpMatching2 | 7vjNQ6Z1op0 | func |
| libSceNpMatching2 | LhCPctIICxQ | func |
| libSceNpMatching2 | rJNPJqDCpiI | func |
| libSceNpMatching2 | p+2EnxmaAMM | func |
| libSceNpMatching2 | uBESzz4CQws | func |
| libSceNpMatching2 | 0UMeWRGnZKA | func |
| libSceNpMatching2 | zCWZmXXN600 | func |
| libSceNpMatching2 | BD6kfx442Do | func |
| libSceNpMatching2 | CSIMDsVjs-g | func |
| libSceNpMatching2 | q7GK98-nYSE | func |
| libSceNpMatching2 | 26vWrPAWJfM | func |
| libSceNpMatching2 | qeF-q5KDtAc | func |
| libSceNpTus | pgcNwFHoOL4 | func |
| libSceNpTus | XOzszO4ONWU | func |
| libSceNpTus | 2eq1bMwgZYo | func |
| libSceNpTus | 4NrufkNCkiE | func |
| libSceNpTrophy | E1Wrwd07Lr8 | func |
| libSceNpScore | KnNA1TEgtBI | func |
| libSceNpScore | G0pE+RNCwfk | func |
| libSceNpScore | gW8qyjYrUbk | func |
| libSceNpScore | zT0XBtgtOSI | func |
| libSceNpScore | KBHxDjyk-jA | func |
| libSceNpScore | 9mZEgoiEq6Y | func |
| libSceNpScore | dK8-SgYf6r4 | func |
| libSceNpWebApi | 743ZzEBzlV8 | func |
| libSceNpWebApi | VwJ5L0Higg0 | func |
| libSceNpCommon | i8UmXTSq7N4 | func |
| libSceRtc | NxEI1KByvCI | func |
| libSceNpMatching2 | Mqp3lJ+sjy4 | func |
| libSceNpMatching2 | meEjIdbjAA0 | func |
| libSceNpMatching2 | +8e7wXLmjds | func |
| libSceNpMatching2 | VqZX7POg2Mk | func |
| libSceNpMatching2 | Iw2h0Jrrb5U | func |
| libSceNpMatching2 | Jraxifmoet4 | func |
| libSceNpMatching2 | 5lhvOqheFBA | func |
| libSceNpMatching2 | opDpl74pi2E | func |
| libSceNpMatching2 | AUVfU6byg3c | func |
| libSceNpMatching2 | S9D8JSYIrjE | func |
| libSceNpMatching2 | HoqTrkS9c5Q | func |
| libSceNpMatching2 | twVupeaYYrk | func |
| libSceNpManager | bMG3cVmUmuk | func |
| libSceNpUtility | jktww3yJXnc | func |
| libSceNpUtility | BYIZGKm6bO4 | func |
| libSceNpUtility | pLr1fEQS1z8 | func |
| libSceNpScore | ANJssPz3mY0 | func |
| libSceNpScore | Rd27dqUFZV8 | func |
| libSceNpScore | rShmqXHwoQE | func |
| libSceNpScore | 8kuIzUw6utQ | func |
| libSceNpScore | 7SuMUlN7Q6I | func |
| libSceNpSns | OoTjfxl8-wI | func |
| libSceNpSns | VtyS8XLBqNE | func |
| libSceNpSns | pTvAKV1iQkE | func |
| libSceNpTrophy | eBL+l6HG9xk | func |
| libSceNpTrophy | w4uMPmErD4I | func |
| libSceNpTrophy | HLwz1fRIycA | func |
| libSceNpTus | 1Cz0hTJFyh4 | func |
| libSceNpTus | c6aYoa47YgI | func |
| libSceNpTus | uFxVYJEkcmc | func |
| libSceNpTus | F+eQlfcka98 | func |
| libSceNpTus | +RhzSuuXwxo | func |
| libSceNpTus | GQHCksS7aLs | func |
| libSceNpUtility | t0P5z5yuFPA | func |
| libSceNpUtility | r9BgI0PfJZg | func |
| libSceNpUtility | 1dMndqL-QgE | func |
| libSceNpUtility | Jj4mkpFO2gE | func |
| libSceNpScore | LoVMVrijVOk | func |
| libSceNpScore | 1i7kmKbX6hk | func |
| libSceNpScore | m1DfNRstkSQ | func |
| libSceNpTrophy | YYP3f2W09og | func |
| libSceNpTrophy | wTUwGfspKic | func |
| libSceNpUtility | iCq5xW5KQW4 | func |
| libSceNpUtility | IEB+vgVoQbw | func |
| libSceNpUtility | PYFS1H70bDs | func |
| libSceNpUtility | rAOOqDAxBIk | func |
| libSceNpUtility | ur5SShyG0dk | func |
| libc | u0XOsuOmOzc | func |
| libc | Jo9ON-AX9eU | func |
| libSceNgs2 | t9T0QM17Kvo | func |
| libc | NDcSfcYZRC8 | func |
| libc | fiOgmWkP+Xc | func |
| libc | iU0z6SdUNbI | func |
| libSceGnmDriver | QhnyReteJ1M | func |
| libSceGnmDriver | jiItzS6+22g | func |
| libSceGnmDriver | aj3L-iaFmyk | func |
| libSceGnmDriver | W1Etj-jlW7Y | func |
| libSceGnmDriver | aPIZJTXC+cU | func |
| libSceGnmDriver | 7qZVNgEu+SY | func |
| libSceGnmDriver | 26PM5Mzl8zc | func |
| libSceGnmDriver | RU74kek-N0c | func |
| libSceGnmDriver | iCO804ZgzdA | func |
| libSceGnmDriver | PVT+fuoS9gU | func |
| libSceGnmDriver | UoYY0DWMC0U | func |
| libSceGnmDriver | H7-fgvEutM0 | func |
| libSceGnmDriver | iBt3Oe00Kvc | func |
| libSceGnmDriver | qpGITzPE+Zc | func |
| libSceGnmDriver | b08AgtPlHPg | func |
| libSceGnmDriver | gObODli-OH8 | func |
| libSceGnmDriver | +xuDhxlWRPg | func |
| libSceGnmDriver | f85orjx7qts | func |
| libSceGnmDriver | HHo1BAljZO8 | func |
| libSceGnmDriver | jtkqXpAOY6w | func |
| libSceGnmDriver | u9YKpRRHe-M | func |
| libSceGnmDriver | 4UFagYlfuAM | func |
| libSceGnmDriver | xeTLfxVIQO4 | func |
| libSceGnmDriver | 9thMn+uB1is | func |
| libSceGnmDriver | d88anrgNoKY | func |
| libSceGnmDriver | TLV4mswiZ4A | func |

### sce_module/libc.prx — 0 MISS

(none)

### sce_module/libSceFios2.prx — 0 MISS

(none)

### Exact game-run link-failure lines (verify-b)

```text
  unresolved eboot.bin: IPN-FRSrafk libSceCompanionUtil func
  unresolved eboot.bin: xb1xlIhf0QY libSceCompanionUtil func
  unresolved eboot.bin: H1fYQd5lFAI libSceCompanionUtil func
  unresolved eboot.bin: cE5Msy11WhU libSceCompanionUtil func
  unresolved eboot.bin: 9+g9iOq+7kg libSceInvitationDialog func
  unresolved eboot.bin: 8XKR6wa64iQ libSceInvitationDialog func
  unresolved eboot.bin: B6HVJtDYxEE libSceInvitationDialog func
  unresolved eboot.bin: XvA5KS56wcs libSceInvitationDialog func
  unresolved eboot.bin: 0zU0G+wiVLA libSceInvitationDialog func
  unresolved eboot.bin: NxEI1KByvCI libSceRtc func
  unresolved eboot.bin: t9T0QM17Kvo libSceNgs2 func
  unresolved eboot.bin: QhnyReteJ1M libSceGnmDriver func
  unresolved eboot.bin: jiItzS6+22g libSceGnmDriver func
  unresolved eboot.bin: aj3L-iaFmyk libSceGnmDriver func
  unresolved eboot.bin: W1Etj-jlW7Y libSceGnmDriver func
  unresolved eboot.bin: aPIZJTXC+cU libSceGnmDriver func
  unresolved eboot.bin: 7qZVNgEu+SY libSceGnmDriver func
  unresolved eboot.bin: 26PM5Mzl8zc libSceGnmDriver func
  unresolved eboot.bin: RU74kek-N0c libSceGnmDriver func
  unresolved eboot.bin: iCO804ZgzdA libSceGnmDriver func
  unresolved eboot.bin: PVT+fuoS9gU libSceGnmDriver func
  unresolved eboot.bin: UoYY0DWMC0U libSceGnmDriver func
  unresolved eboot.bin: H7-fgvEutM0 libSceGnmDriver func
  unresolved eboot.bin: iBt3Oe00Kvc libSceGnmDriver func
  unresolved eboot.bin: qpGITzPE+Zc libSceGnmDriver func
  unresolved eboot.bin: b08AgtPlHPg libSceGnmDriver func
  unresolved eboot.bin: gObODli-OH8 libSceGnmDriver func
  unresolved eboot.bin: +xuDhxlWRPg libSceGnmDriver func
  unresolved eboot.bin: f85orjx7qts libSceGnmDriver func
  unresolved eboot.bin: HHo1BAljZO8 libSceGnmDriver func
  unresolved eboot.bin: jtkqXpAOY6w libSceGnmDriver func
  unresolved eboot.bin: u9YKpRRHe-M libSceGnmDriver func
  unresolved eboot.bin: 4UFagYlfuAM libSceGnmDriver func
  unresolved eboot.bin: xeTLfxVIQO4 libSceGnmDriver func
  unresolved eboot.bin: 9thMn+uB1is libSceGnmDriver func
  unresolved eboot.bin: d88anrgNoKY libSceGnmDriver func
  unresolved eboot.bin: TLV4mswiZ4A libSceGnmDriver func

Note: on every capture, the d88anrgNoKY line's stderr text was byte-interleaved
on the terminal with a buffered stdout `[link] node ... 673 imports ... <<APPLY>>`
line, appearing as `unresolved eboot.bin[link] 673 imports r=true <<APPLY>>` plus
a wrapped `: d88anrgNoKY libSceGnmDriver func`. The NID/library/kind above are
reconstructed from that wrap and confirmed present as a `MISS` in module-info
(`0x0000005a5080 MISS d88anrgNoKY libSceGnmDriver/libSceGnmDriver func jump_slot`).
verify-b therefore reports 37 unresolved import lines before aborting; the other
36 were captured clean and all 37 NIDs are a subset of module-info's MISS set.
cannot link /tmp/opencode/verify-b/eboot.bin: UnresolvedImport
```


## ROM: verify-a  (/tmp/opencode/verify-a)

Per-module MISS counts (occurrences):

| module | MISS |
|---|---:|
| eboot.bin | 98 |
| sce_module/libc.prx | 3 |
| sce_module/libSceAudioLatencyEstimation.prx | 0 |
| sce_module/libSceFace.prx | 5 |
| sce_module/libSceFaceTracker.prx | 17 |
| sce_module/libSceFios2.prx | 1 |
| sce_module/libSceHand.prx | 0 |
| sce_module/libSceHandTracker.prx | 0 |
| sce_module/libSceHeadTracker.prx | 5 |
| sce_module/libSceJobManager.prx | 54 |
| sce_module/libSceNpToolkit2.prx | 148 |
| sce_module/libSceS3DConversion.prx | 98 |
| **TOTAL** | **429** |

### eboot.bin — 98 MISS

| library | NID | kind |
|---|---|---|
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | aeHxLWwq0gQ | object |
| libc | nOIEswYD4Ig | func |
| libc | Ezzq78ZgHPs | func |
| libc | pNtJdE3x49E | func |
| libc | DbEnA+MnVIw | func |
| libc | WDpobjImAb4 | func |
| libc | d3dMyWORw8A | func |
| libc | Cj+Fw5q1tUo | func |
| libc | 2vDqwBlpF-o | func |
| libc | H8ya2H00jbI | func |
| libc | 2WE3BTYVwKM | func |
| libc | rtV7-jWC6Yg | func |
| libc | WuMbPBKN1TU | func |
| libc | GfxAp9Xyiqs | func |
| libc | lA94ZgT+vMM | func |
| libc | CyXs2l-1kNA | func |

### sce_module/libc.prx — 3 MISS

| library | NID | kind |
|---|---|---|
| libSceFios2 | oRgsgfJY3Mc | func |
| libSceFios2 | +mfO27a-bEY | func |
| libSceFios2 | 8dzXU5GxsjI | func |

### sce_module/libSceAudioLatencyEstimation.prx — 0 MISS

(none)

### sce_module/libSceFace.prx — 5 MISS

| library | NID | kind |
|---|---|---|
| libSceLibcInternal | iz2shAGFIxc | func |
| libSceLibcInternal | pztV4AF18iI | func |
| libSceLibcInternal | RQXLbdT2lc4 | func |
| libSceLibcInternal | -P6FNMzk2Kc | func |
| libSceLibcInternal | Q4rRL34CEeE | func |

### sce_module/libSceFaceTracker.prx — 17 MISS

| library | NID | kind |
|---|---|---|
| libSceFace | 37DR-ZKbsv8 | func |
| libSceFace | +sAja0b9rZU | func |
| libSceFace | +0E0dyw8phY | func |
| libSceFace | FTnplTtBnw8 | func |
| libSceFace | ibYWv3khTDw | func |
| libSceFace | kZ5Cc0KqzdI | func |
| libSceFace | WzOBQR6MNWA | func |
| libSceFace | AsxmyXFDsiM | func |
| libSceFace | DYdXC4Ixa4s | func |
| libSceFace | ZyC0HzaV6VU | func |
| libSceFace | mz0+WE5XkSc | func |
| libSceFace | uiyG1M9D8-4 | func |
| libSceFace | j7lvkiMu1Sg | func |
| libSceFace | rZYoZcqqJdo | func |
| libSceFace | BsmV0JLSdpg | func |
| libSceFace | 4eUBMHs41k0 | func |
| libSceFace | 47S+J03eask | func |

### sce_module/libSceFios2.prx — 1 MISS

| library | NID | kind |
|---|---|---|
| libSceSysmodule | hHrGoGoNf+s | func |

### sce_module/libSceHand.prx — 0 MISS

(none)

### sce_module/libSceHandTracker.prx — 0 MISS

(none)

### sce_module/libSceHeadTracker.prx — 5 MISS

| library | NID | kind |
|---|---|---|
| libSceLibcInternal | pztV4AF18iI | func |
| libSceLibcInternal | -P6FNMzk2Kc | func |
| libSceLibcInternal | iz2shAGFIxc | func |
| libSceLibcInternal | RQXLbdT2lc4 | func |
| libSceLibcInternal | Q4rRL34CEeE | func |

### sce_module/libSceJobManager.prx — 54 MISS

| library | NID | kind |
|---|---|---|
| ulobjmgr | BG26hBGiNlw | func |
| libSceLibcInternal | 3BytPOQgVKc | func |
| ulobjmgr | Smf+fUNblPc | func |
| libSceRazorCpu | KP+TBWGHlgs | func |
| libSceRazorCpu | dnEdyY4+klQ | func |
| libSceRazorCpu | 9FowWFMEIM8 | func |
| libSceGnmDriver | Kx-h-nWQJ8A | func |
| libSceGnmDriver | b08AgtPlHPg | func |
| libSceGnmDriver | ihxrbsoSKWc | func |
| libSceGnmDriver | ffrNQOshows | func |
| libSceGnmDriver | EJapNl2+pgU | func |
| libSceGnmDriver | 5udAm+6boVg | func |
| libSceGnmDriver | qpGITzPE+Zc | func |
| libSceGnmDriver | jtkqXpAOY6w | func |
| libSceGnmDriver | XiyzNZ9J4nQ | func |
| libSceGnmDriver | +xuDhxlWRPg | func |
| libSceGnmDriver | Ga6r7H6Y0RI | func |
| libSceGnmDriver | jRcI8VcgTz4 | func |
| libSceGnmDriver | PVT+fuoS9gU | func |
| libSceGnmDriver | UtObDRQiGbs | func |
| libSceGnmDriver | byXlqupd8cE | func |
| libSceGnmDriver | HHo1BAljZO8 | func |
| libSceGnmDriver | 0BzLGljcwBo | func |
| libSceGnmDriver | wED4ZXCFJT0 | func |
| libSceGnmDriver | TLV4mswiZ4A | func |
| libSceGnmDriver | R6z1xM3pW-w | func |
| libSceGnmDriver | d88anrgNoKY | func |
| libSceGnmDriver | Fa3x75OOLRA | func |
| libSceGnmDriver | iBt3Oe00Kvc | func |
| libSceGnmDriver | UoYY0DWMC0U | func |
| libSceGnmDriver | H7-fgvEutM0 | func |
| libSceGnmDriver | oL4hGI1PMpw | func |
| libSceGnmDriver | Fwvh++m9IQI | func |
| libSceGnmDriver | tZCSL5ulnB4 | func |
| libSceGnmDriver | iFirFzgYsvw | func |
| libSceGnmDriver | KnldROUkWJY | func |
| libSceGnmDriver | FFVZcCu3zWU | func |
| libSceGnmDriver | dewXw5roLs0 | func |
| libSceGnmDriver | fzJdEihTFV4 | func |
| libSceGnmDriver | nEyFbYUloIM | func |
| libSceGnmDriver | k7iGTvDQPLQ | func |
| libSceGnmDriver | NfvOrNzy6sk | func |
| libSceGnmDriver | 7qZVNgEu+SY | func |
| libSceGnmDriver | aPIZJTXC+cU | func |
| libSceGnmDriver | W1Etj-jlW7Y | func |
| libSceGnmDriver | aj3L-iaFmyk | func |
| libSceGnmDriver | jiItzS6+22g | func |
| libSceGnmDriver | 26PM5Mzl8zc | func |
| libSceGnmDriver | RU74kek-N0c | func |
| libSceGnmDriver | A+uGq+3KFtQ | func |
| libSceGnmDriver | u9YKpRRHe-M | func |
| libSceGnmDriver | gObODli-OH8 | func |
| libSceGnmDriver | 6YRHhh5mHCs | func |
| libSceGnmDriver | f85orjx7qts | func |

### sce_module/libSceNpToolkit2.prx — 148 MISS

| library | NID | kind |
|---|---|---|
| libSceNpAuth | qAUXQ9GdWp8 | func |
| libSceNpAuth | CocbHVIKPE8 | func |
| libSceNpAuth | cE7wIsqXdZ8 | func |
| libSceRtc | NxEI1KByvCI | func |
| libSceNpProfileDialog | nrQRlLKzdwE | func |
| libSceNpMatching2 | KC+GnHzrK2o | func |
| libSceNpMatching2 | vbtWT3lZBOM | func |
| libSceNpMatching2 | nNeC3F8-g+4 | func |
| libSceNpMatching2 | 10t3e5+JPnU | func |
| libSceNpMatching2 | Nz-ZE7ur32I | func |
| libSceNpMatching2 | -f6M4caNe8k | func |
| libSceNpMatching2 | ajvzc8e2upo | func |
| libSceNpMatching2 | fQQfP87I7hs | func |
| libSceNpMatching2 | 7vjNQ6Z1op0 | func |
| libSceNpMatching2 | LhCPctIICxQ | func |
| libSceNpMatching2 | uBESzz4CQws | func |
| libSceNpMatching2 | 0UMeWRGnZKA | func |
| libSceNpMatching2 | p+2EnxmaAMM | func |
| libSceNpMatching2 | rJNPJqDCpiI | func |
| libSceNpMatching2 | V6KSpKv9XJE | func |
| libSceNpMatching2 | S9D8JSYIrjE | func |
| libSceNpMatching2 | VqZX7POg2Mk | func |
| libSceNpMatching2 | gQ6cUriNpgs | func |
| libSceNpMatching2 | cgQhq3E0eGo | func |
| libSceNpMatching2 | 26vWrPAWJfM | func |
| libSceNpMatching2 | BD6kfx442Do | func |
| libSceNpMatching2 | 5lhvOqheFBA | func |
| libSceNpMatching2 | Jraxifmoet4 | func |
| libSceNpMatching2 | HoqTrkS9c5Q | func |
| libSceNpMatching2 | q7GK98-nYSE | func |
| libSceNpMatching2 | ES3UMUWWj9U | func |
| libSceNpMatching2 | AUVfU6byg3c | func |
| libSceNpMatching2 | wUmwXZHaX1w | func |
| libSceNpMatching2 | opDpl74pi2E | func |
| libSceNpMatching2 | Iw2h0Jrrb5U | func |
| libSceNpMatching2 | Mqp3lJ+sjy4 | func |
| libSceNpMatching2 | meEjIdbjAA0 | func |
| libSceNpMatching2 | GyI2f9yDUXM | func |
| libSceLibcInternal | W6SiVSiCDtI | func |
| libSceNpWebApi | 3OnubUs02UM | func |
| libSceNet | rMyh97BU5pY | func |
| libSceNpManager | Ubv+fP58W1U | func |
| libSceNpMatching2 | gpSAvdheZ0Q | func |
| libSceNpMatching2 | 8btynvj0KNA | func |
| libSceNpManager | PQDFxcnqxtw | func |
| libSceNpUtility | jktww3yJXnc | func |
| libSceNpUtility | BYIZGKm6bO4 | func |
| libSceNpUtility | pLr1fEQS1z8 | func |
| libSceNpUtility | kvdMF48mB3Y | func |
| libSceNpManager | IkL62FMpIpo | func |
| libSceNpManager | bMG3cVmUmuk | func |
| libSceNetCtlForNpToolkit | wIsKy+TfeLs | func |
| libSceUserServiceForNpToolkit | wuI7c7UNk0A | func |
| libSceNpManagerForToolkit | 0c7HbXRKUt4 | func |
| libSceNetCtlForNpToolkit | 2oUqKR5odGc | func |
| libSceUserServiceForNpToolkit | spW--yoLQ9o | func |
| libSceNetCtlForNpToolkit | u5oqtlIP+Fw | func |
| libSceNpManagerForToolkit | JELHf4xPufo | func |
| libSceNpManagerForToolkit | YIvqqvJyjEc | func |
| libSceNpManager | 8Z2Jc5GvGDI | func |
| libSceNpScore | G0pE+RNCwfk | func |
| libSceNpScore | GWnWQNXZH5M | func |
| libSceNpScore | gW8qyjYrUbk | func |
| libSceNpScore | bygbKdHmjn4 | func |
| libSceNpScore | AgcxgceaH8k | func |
| libSceNpScore | dK8-SgYf6r4 | func |
| libSceNpScore | gMbOn+-6eXA | func |
| libSceNpScore | nRoYV2yeUuw | func |
| libSceNpScore | MA9vSt7JImY | func |
| libSceNpScore | 3Ybj4E1qNtY | func |
| libSceNpScore | oXjVieH6ZGQ | func |
| libSceNpScore | K9tlODTQx3c | func |
| libSceNpScore | wJPWycVGzrs | func |
| libSceNpScore | Lmtc9GljeUA | func |
| libSceNpScore | bcoVwcBjQ9E | func |
| libSceNpScore | zT0XBtgtOSI | func |
| libSceNpScore | 1i7kmKbX6hk | func |
| libSceNpScore | LoVMVrijVOk | func |
| libSceInvitationDialog | XvA5KS56wcs | func |
| libSceInvitationDialog | sAxbHhAWMXM | func |
| libSceInvitationDialog | 9+g9iOq+7kg | func |
| libSceInvitationDialog | WuuUhuKOxwQ | func |
| libSceInvitationDialog | B6HVJtDYxEE | func |
| libSceNpTrophy | E1Wrwd07Lr8 | func |
| libSceNpTrophy | cqGkYAN-gRw | func |
| libSceNpTrophy | d9jpdPz5f-8 | func |
| libSceNpTrophy | YYP3f2W09og | func |
| libSceNpTrophy | HLwz1fRIycA | func |
| libSceNpTrophy | wTUwGfspKic | func |
| libSceNpTrophy | w4uMPmErD4I | func |
| libSceNpTrophy | eBL+l6HG9xk | func |
| libSceNpTrophy | aTnHs7W-9Uk | func |
| libSceNpTus | lBtrk+7lk14 | func |
| libSceNpTus | 2eq1bMwgZYo | func |
| libSceNpTus | 1n-dGukBgnY | func |
| libSceNpTus | 1Cz0hTJFyh4 | func |
| libSceNpTus | cf-WMA0jYCc | func |
| libSceNpTus | fcCwKpi4CbU | func |
| libSceNpTus | oGIcxlUabSA | func |
| libSceNpTus | MGvSJEHwyL8 | func |
| libSceNpTus | 0up4MP1wNtc | func |
| libSceNpTus | wTuuw4-6HI8 | func |
| libSceNpTus | m9XZnxw9AmE | func |
| libSceNpTus | AsziNQ9X2uk | func |
| libSceNpTus | GDXlRTxgd+M | func |
| libSceNpTus | mD6s8HtMdpk | func |
| libSceNpTus | C8TY-UnQoXg | func |
| libSceNpTus | 4VLlu7EIjzk | func |
| libSceNpTus | EPeq43CQKxY | func |
| libSceNpTus | Nt1runsPVJc | func |
| libSceNpTus | wPFah4-5Xec | func |
| libSceNpTus | Djuj2+1VNL0 | func |
| libSceNpTus | fVvocpq4mG4 | func |
| libSceNpTus | Q5uQeScvTPE | func |
| libSceNpTus | Gjixv5hqRVY | func |
| libSceNpTus | w-c7U0MW2KY | func |
| libSceNpTus | fJU2TZId210 | func |
| libSceNpTus | cVeBif6zdZ4 | func |
| libSceNpTus | lxNDPDnWfMc | func |
| libSceNpTus | kbWqOt3QjKU | func |
| libSceNpTus | VzxN3tOouj8 | func |
| libSceNpTus | -LxFGYCJwww | func |
| libSceNpTus | 1TE3OvH61qo | func |
| libSceNpTus | iaH+Sxlw32k | func |
| libSceNpTus | yWEHUFkY1qI | func |
| libSceNpTus | xutwCvsydkk | func |
| libSceNpTus | iXzUOM9sXU0 | func |
| libSceNpTus | TDoqRD+CE+M | func |
| libSceNpTus | yixh7HDKWfk | func |
| libSceNpWebApi | pfaJtb7SQ80 | func |
| libSceNpWebApi | PqCY25FMzPs | func |
| libSceNpWebApi | joRjtRXTFoc | func |
| libSceNpWebApi | KjNeZ-29ysQ | func |
| libSceNpWebApi | 743ZzEBzlV8 | func |
| libSceNpWebApi | VwJ5L0Higg0 | func |
| libSceNpWebApi | zk6c65xoyO0 | func |
| libSceLibcInternal | VOBg+iNwB-4 | func |
| libSceNpWebApi | jhXKGQJ4egI | func |
| libSceNpWebApi | M2BUB+DNEGE | func |
| libSceNpUtility | 6p9jvljuvsw | func |
| libSceNpUtility | iCq5xW5KQW4 | func |
| libSceNpUtility | Jj4mkpFO2gE | func |
| libSceNpUtility | PYFS1H70bDs | func |
| libSceNpUtility | rAOOqDAxBIk | func |
| libSceNpUtility | t0P5z5yuFPA | func |
| libSceLibcInternal | V02oFv+-JzA | func |
| libSceLibcInternal | GfxAp9Xyiqs | func |
| libSceLibcInternal | dhK16CKwhQg | func |

### sce_module/libSceS3DConversion.prx — 98 MISS

| library | NID | kind |
|---|---|---|
| libSceGnmDriverResourceRegistration | j6mSQs3UgaY | func |
| libSceLibcInternal | 2WE3BTYVwKM | func |
| libSceGnmDriver | Kx-h-nWQJ8A | func |
| libSceGnmDriver | b08AgtPlHPg | func |
| libSceGnmDriver | ihxrbsoSKWc | func |
| libSceGnmDriver | X9Omw9dwv5M | func |
| libSceGnmDriver | ffrNQOshows | func |
| libSceGnmDriver | EJapNl2+pgU | func |
| libSceGnmDriver | 5udAm+6boVg | func |
| libSceGnmDriver | qpGITzPE+Zc | func |
| libSceGnmDriver | +AFvOEXrKJk | func |
| libSceGnmDriver | jtkqXpAOY6w | func |
| libSceGnmDriver | 5uFKckiJYRM | func |
| libSceGnmDriver | q-qhDxP67Hg | func |
| libSceGnmDriver | K3BKBBYKUSE | func |
| libSceGnmDriver | cFCp0NX8wf0 | func |
| libSceGnmDriver | XiyzNZ9J4nQ | func |
| libSceGnmDriver | +xuDhxlWRPg | func |
| libSceGnmDriver | Ga6r7H6Y0RI | func |
| libSceGnmDriver | jRcI8VcgTz4 | func |
| libSceGnmDriver | PVT+fuoS9gU | func |
| libSceGnmDriver | UtObDRQiGbs | func |
| libSceGnmDriver | byXlqupd8cE | func |
| libSceGnmDriver | HHo1BAljZO8 | func |
| libSceGnmDriver | 0BzLGljcwBo | func |
| libSceGnmDriver | Z43vKp5k7r0 | func |
| libSceGnmDriver | wED4ZXCFJT0 | func |
| libSceGnmDriver | HlTPoZ-oY7Y | func |
| libSceGnmDriver | GGsn7jMTxw4 | func |
| libSceGnmDriver | ED9-Fjr8Ta4 | func |
| libSceGnmDriver | thbPcG7E7qk | func |
| libSceGnmDriver | jHdPvIzlpKc | func |
| libSceGnmDriver | oYM+YzfCm2Y | func |
| libSceGnmDriver | 4v+otIIdjqg | func |
| libSceGnmDriver | cUCo8OvArrw | func |
| libSceGnmDriver | yb2cRhagD1I | func |
| libSceGnmDriver | im2ZuItabu4 | func |
| libSceGnmDriver | stDSYW2SBVM | func |
| libSceGnmDriver | TLV4mswiZ4A | func |
| libSceGnmDriver | yhFCnaz5daw | func |
| libSceGnmDriver | fhKwCVVj9nk | func |
| libSceGnmDriver | k8EXkhIP+lM | func |
| libSceGnmDriver | nLM2i2+65hA | func |
| libSceGnmDriver | GNlx+y7xPdE | func |
| libSceGnmDriver | mLVL7N7BVBg | func |
| libSceGnmDriver | V31V01UiScY | func |
| libSceGnmDriver | R6z1xM3pW-w | func |
| libSceGnmDriver | d88anrgNoKY | func |
| libSceGnmDriver | Fa3x75OOLRA | func |
| libSceGnmDriver | 4Mv9OXypBG8 | func |
| libSceGnmDriver | iBt3Oe00Kvc | func |
| libSceGnmDriver | SXw4dZEkgpA | func |
| libSceGnmDriver | BgM3t3LvcNk | func |
| libSceGnmDriver | qGP74T5OWJc | func |
| libSceGnmDriver | hsZPf1lON7E | func |
| libSceGnmDriver | RX7XCNSaL6I | func |
| libSceGnmDriver | UoYY0DWMC0U | func |
| libSceGnmDriver | H7-fgvEutM0 | func |
| libSceGnmDriver | oL4hGI1PMpw | func |
| libSceGnmDriver | Fwvh++m9IQI | func |
| libSceGnmDriver | tZCSL5ulnB4 | func |
| libSceGnmDriver | iFirFzgYsvw | func |
| libSceGnmDriver | KnldROUkWJY | func |
| libSceGnmDriver | FFVZcCu3zWU | func |
| libSceGnmDriver | QJjPjlmPAL0 | func |
| libSceGnmDriver | dewXw5roLs0 | func |
| libSceGnmDriver | fzJdEihTFV4 | func |
| libSceGnmDriver | 4PKnYXOhcx4 | func |
| libSceGnmDriver | O0S96YnD04U | func |
| libSceGnmDriver | UBv7FkVfzcQ | func |
| libSceGnmDriver | bdqdvIkLPIU | func |
| libSceGnmDriver | UoBuWAhKk7U | func |
| libSceGnmDriver | nEyFbYUloIM | func |
| libSceGnmDriver | k7iGTvDQPLQ | func |
| libSceGnmDriver | 5SHGNwLXBV4 | func |
| libSceGnmDriver | HzMN7ANqYEc | func |
| libSceGnmDriver | rTIV11nMQuM | func |
| libSceGnmDriver | NfvOrNzy6sk | func |
| libSceGnmDriver | 7qZVNgEu+SY | func |
| libSceGnmDriver | aPIZJTXC+cU | func |
| libSceGnmDriver | W1Etj-jlW7Y | func |
| libSceGnmDriver | aj3L-iaFmyk | func |
| libSceGnmDriver | jiItzS6+22g | func |
| libSceGnmDriver | MBMa6EFu4Ko | func |
| libSceGnmDriver | 26PM5Mzl8zc | func |
| libSceGnmDriver | RU74kek-N0c | func |
| libSceGnmDriver | Kl0Z3LH07QI | func |
| libSceGnmDriver | A+uGq+3KFtQ | func |
| libSceGnmDriver | Q7t4VEYLafI | func |
| libSceGnmDriver | u9YKpRRHe-M | func |
| libSceGnmDriver | 6IMbpR7nTzA | func |
| libSceGnmDriver | 9Mv61HaMhfA | func |
| libSceGnmDriver | ZFqKFl23aMc | func |
| libSceGnmDriver | nvEwfYAImTs | func |
| libSceGnmDriver | gObODli-OH8 | func |
| libSceGnmDriver | 6YRHhh5mHCs | func |
| libSceGnmDriver | f85orjx7qts | func |
| libSceGnmDriver | MYRtYhojKdA | func |

### Exact game-run link-failure lines (verify-a)

```text
  unresolved sce_module/libSceFios2.prx: hHrGoGoNf+s libSceSysmodule func
cannot link /tmp/opencode/verify-a/eboot.bin: RelocationTargetUnavailable
```

