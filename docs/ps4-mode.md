<!--
Copyright (C) 2026 PS5PCEM Project
SPDX-License-Identifier: GPL-3.0-or-later
-->

# PS4 Mode: Experimental GNM/GCN Backward Compatibility

`ps4_mode` is PS5PCEM's analogue of SharpEmu's GNM mode (sharpemu@8ddf660,
"Tessellation + Draw reuse and GNM mode"). Same principle: **no separate PS4
emulator**. PS4 titles keep their interfaces; a compat layer translates the
PS4-specific parts into the existing PS5-oriented runtime.

## What it does

| SharpEmu GNM step | PS5PCEM `src/ps4_mode/` equivalent |
|---|---|
| Detect compatibility applications | `detector.zig` — TITLE_ID prefix (CUSA/PCAS = PS4, PPSA/ELAS = PS5) + ELF `e_type` (PS4 `0xFE00` vs PS5 `0xFE10`) + combined `decide()` |
| Parse decrypted ELF/SELF, param SFO | `sfo.zig` — read-only param.sfo parser (`TITLE_ID`, `CATEGORY`, …); ELF/SELF reuse `src/loader/` |
| Decode shader stage resources, tessellation programs | `gcn_header.zig` — OrbShdr stage/SGPR/VGPR/tess + hull-pair flags, stage-slot mapping for `rdna2/` + `gpu/` |
| Translate command packets into shared GPU work | `gnm_packets.zig` — GNM dword stream → neutral `WorkItem` (draw/dispatch/barrier/set_reg/unsupported); unknown ops pass through, truncated tails report cleanly |
| Thin 1D tiling, guest row pitches, volume chains | `image_layout.zig` — pure tiling/pitch math; detiling stays in `gpu/tiling.zig` |
| Compatibility library exports | `compat_hle.zig` — per-library `passthrough|adapt|stub|unsupported` table consumed by HLE wiring |
| Launch compat apps, LoadExec restart, env switches | `runtime.zig` — `PS5_PS4_MODE=auto|on|off`, `PS5_GNM_DIAG=0|1`, `Session` with `retarget()` for LoadExec |

## Usage

```sh
# build + run only this module's tests (no full-suite wait)
zig build test-ps4mode

# force PS4 mode for a directory game-run would otherwise treat as PS5
PS5_PS4_MODE=on zig build game-run -- --app0 /path/to/game eboot.bin
```

Policy resolution (`runtime.Config.enabledFor`): `on` always enables, `off`
always disables, `auto` (default) enables only when `detector` reports
`ps4_gnm`.

## Integration points for the refining AI

1. **Loader** (`src/loader/`): accept PS4 `e_type` values in `elf.zig`
   (`0xFE00`/`0xFE01`) when `ps4_mode` is active; route `sce_sys/param.sfo`
   through `sfo.zig` for the title id.
2. **HLE** (`src/hle/root.zig` `registerAll`): consult
   `compat_hle.lookup()` to pick PS4-layout entry points
   (`libSceGnmDriver`, `libSceVideoOut`, …) vs native PS5 ones.
3. **GPU** (`src/gpu/`): feed `gnm_packets.translateStream()` output into the
   existing executor/scheduler; bind `gcn_header.stageSlot()` at pipeline
   creation; use `image_layout` pitch/tiling when creating cached images.
4. **Launchers** (`src/launcher*.zig`, `src/game_run.zig`): cache
   `detector.Mode` per title, badge PS4 titles, restart the session via
   `Session.retarget()` on guest LoadExec.
5. **Tessellation**: `gcn_header` flags HS/DS pairs; actual HS+DS lowering
   stays in `gpu/tessellation.zig` + `rdna2/`.

## Status

Scaffold + tested decode/translation primitives. No renderer/HLE behavior
changes yet — the main build is untouched apart from registering the module
and its tests. See `docs/ps4-mode-design.md` for the roadmap.
