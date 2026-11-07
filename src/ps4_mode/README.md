# PS4 Mode (experimental)

Implemented by kleinergoo7.

Experimental PS4 (GNM/GCN) backward compatibility for PS5PCEM, analogous to
SharpEmu's GNM mode: PS4 titles keep their interfaces, and this layer
translates detection, shader metadata, command packets and image layouts into
representations the existing PS5-oriented path already understands.

Modules (`src/ps4_mode/`, canonical root `root.zig`):

- `sfo.zig` — read-only param.sfo parser
- `detector.zig` — PS4 vs PS5 title classification
- `gcn_header.zig` — OrbShdr stage/tessellation metadata
- `gnm_packets.zig` — GNM dword stream → neutral work items
- `image_layout.zig` — thin/thick tiling + pitch math
- `compat_hle.zig` — per-library passthrough/adapt/stub table
- `runtime.zig` — `PS5_PS4_MODE` / `PS5_GNM_DIAG` env, LoadExec sessions

Run: `zig build test-ps4mode` (Zig 0.16; the module itself is also
0.17-clean). Full doc: `docs/ps4-mode.md`.
