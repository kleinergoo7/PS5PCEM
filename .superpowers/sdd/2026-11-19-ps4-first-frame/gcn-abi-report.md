# GCN shader ABI investigation (branch `gcn-abi`)

**Status: FOUND** — Terraria's real GCN shader binaries are present in guest
memory as `OrbShdr` blobs, in two regions. The values passed to the two GNM
shader-set imports are **not** the blobs; they are small descriptors/handles in
a separate 0x1_0000_0000-region buffer (the coordinator's first-call zeros are
correct but misleading).

Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-abi` (branch `gcn-abi`, base `3dadccb`).

## Where the real blobs live

| Region | Guest VA range | Count | What |
|---|---|---|---|
| eboot image (SELF load bias `0x40000`) | `0x50a820` .. `0x50bdc0` | 15 | blobs embedded in `eboot.bin` at file offsets `0x4cdcb0` .. `0x4cf250`; guest VA = file offset + `0x3cb70` |
| `ps4heap` mapping | `0x20d806560` .. `0x20d82197c` (and beyond) | 30+ | runtime-loaded / decompressed blobs from game content — these are the shaders Terraria actually draws with |

Both regions were found by scanning every readable guest mapping for the
`OrbShdr` magic; the eboot blobs byte-match the 15 blobs in the on-disk
`eboot.bin`, confirming the mapping.

## The shader-set imports (pointer chain, partial)

- First calls: `sceGnmSetVsShader(0x1000000a88, rsi=0x1d)`,
  `sceGnmSetPsShader(0x1000000aa4, rsi=0x28)` (rsi = shader modifier).
  Later calls use other slots in the same 0x1_0000_0xxx / 0x1_0004_0xxx
  region; VS and PS slots are consistently `0x1c` bytes apart.
- `readGuestMemory` at those pointers succeeds but returns all zeros on the
  first calls; dereferencing once returns `0x0`. Later calls (e.g.
  `0x1000000a40`) contain non-zero PM4/register-like dwords (e.g.
  `0x00fff000`, `0xc0087600`) — i.e. this region is a command/register area,
  not shader code.
- **The descriptor → blob link is not yet established** (see Concerns). The
  blobs themselves are unambiguous and fully dumped.

## Exact command + key output

```sh
cd /home/reng/projects/ps5_zig_emu/.worktrees/gcn-abi
ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
  /home/reng/tools/zig-x86_64-linux-0.16.0/zig build build-game-run
PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 \
  timeout -s TERM 30 ./zig-out/bin/game-run \
  --app0 /tmp/opencode/verify-b /tmp/opencode/verify-b/eboot.bin \
  > /tmp/opencode/gcn-diag-run5.log 2>&1
```

(Temporary diagnostics were in `src/hle/libs/ps4_title_stubs.zig` and have
been reverted; see commits below.) Key lines from
`/tmp/opencode/gcn-diag-run5.log`:

```
[GCNDIAG] VS call=1 shader=0x1000000a88 rdi=0x1000000a88 rsi=0x1d rsp=0x7e0227ae0 ...
[GCNDIAG]   read 128 @ 0x1000000a88 OK   -> all zeros
[GCNDIAG]   *shader = 0x0
[GCNDIAG] PS call=2 shader=0x1000000aa4 rsi=0x28 -> all zeros, *shader = 0x0
[GCNDIAG] scanning 48 mappings for OrbShdr
[GCNDIAG] SCAN : OrbShdr @ 0x50a820 ... 0x50bdc0        (15 eboot blobs)
[GCNDIAG] SCAN ps4heap: OrbShdr @ 0x20d806560 ... 0x20d82197c  (30+ heap blobs)
```

## Dumped blobs (signed with stage)

Runtime guest-memory dumps (from the instrumented run):

- `/tmp/opencode/gcn-blob--4.bin` — **VS**, guest VA `0x50adbc`, 2048 bytes.
- `/tmp/opencode/gcn-blob--3.bin` — **PS**, guest VA `0x50ac44`, 2048 bytes.
- `/tmp/opencode/gcn-blob--1.bin`, `--2`, `--5`, `--6` — more PS blobs.
- `/tmp/opencode/gcn-blob-ps4heap-1..6.bin` — real runtime-loaded heap blobs.
- `/tmp/opencode/gcn-known-0-0x50a820.bin`, `-1-0x20d806560.bin`,
  `-2-0x20d809440.bin`, `-3-0x20d811454.bin`, `-4-0x20d81c5d8.bin` — 4096-byte direct dumps at known addresses.
- Descriptor windows: `/tmp/opencode/gcn-desc-VS-0x1000000a88.bin`,
  `/tmp/opencode/gcn-desc-PS-0x1000000aa4.bin` (512 bytes each).

On-disk eboot-derived copies (identical bytes, for convenience):

- `/tmp/opencode/gcn-eboot-vs-0x4ce24c.bin` — VS (guest `0x50adbc`).
- `/tmp/opencode/gcn-eboot-ps-0x4ce0d4.bin` — PS (guest `0x50ac44`).

## Real OrbShdr header layout (differs from `gcn_header.zig`)

`src/ps4_mode/gcn_header.zig` documents a simplified layout
(`"OrbShdr\0"`, stage at byte 8, ISA offset/size at 12/16) that **does not
match shipped blobs**. Real layout observed:

- `[0..8]` = `"OrbShdr"` + version byte `0x07` (magic bytes `4f 72 62 53 68 64 72 07`).
- `[14..16]` = u16 stage field: `8 = vertex`, `12 = pixel` (confirmed by ISA
  exports: VS ends in `exp pos0` `0xf8001c0f`, PS ends in `exp mrt0` `0xf80008cf`).
- An inner `"Shdr\x07\x00\x01\x00"` header appears later in the blob.
- GCN ISA starts with prolog dword `0xbeeb03ff` and ends with `s_endpgm`
  `0xbf810000`. ISA offset is found by scanning, not by a fixed field.

### VS blob (`0x50adbc`, dump `gcn-blob--4.bin`)

- stage = vertex (field `0x0008`); inner Shdr at blob+`0xa8`.
- isa_offset = `0x104`, isa_size = `88` bytes (22 dwords, prolog + s_endpgm).
- First 16 ISA dwords:
  `beeb03ff 0000000e be92047e befe0a7e c0800300 bf8c007f c2480104 c2400100 bf8c007f 7e000210 7e020211 3e000400 3e020601 f0800f00 00610000 befe0412`
- `num_sgprs`/`num_vgprs`: the inner-Shdr word at blob+`0xb0` is
  `0x00001302` (`0x13`/`0x02` packed); the exact SGPR/VGPR encoding was not
  independently verified.

### PS blob (`0x50ac44`, dump `gcn-blob--3.bin`)

- stage = pixel (field `0x000c`); inner Shdr at blob+`0x100`.
- isa_offset = `0x138`, isa_size = `64` bytes (16 dwords).
- First 16 ISA dwords:
  `beeb03ff 00000007 36020081 34020281 360000c2 4a0202c1 4a0000c1 7e020b01 7e000b00 7e040280 7e0602f2 f80008cf 03020001 f800020f 03030303 bf810000`

## Clean code committed

- `src/ps4_mode/gcn_blob.zig` — reusable reader for real OrbShdr blobs
  (`parse`, `isaBytes`, `Stage`), with two unit tests using a captured VS blob.
- `src/ps4_mode/root.zig` — exports `gcn_blob`.
- No diagnostics, no `src/gpu/**`, no PS5/shared changes committed.

Verification: `zig build test-ps4mode` exit 0; full `zig build test` exit 0.

## Concerns / next steps

1. **Descriptor → blob link unknown.** The shader-set args point into a
   0x1_0000_0xxx command/register region, not to the blobs. To complete the
   chain: reverse `sceGnmSetVsShader`/`sceGnmSetPsShader` in the real
   `libSceGnmDriver.prx` (not present in the extracted tree), or instrument the
   guest shader-upload path (watch for the blob address `0x20d8xxxxx` being
   written into a descriptor slot). The GNM driver likely translates a
   shader GPU VA / register encoding into the blob pointer.
2. **Format fields not fully decoded.** `num_sgprs`/`num_vgprs` and the
   inner-Shdr field semantics are inferred, not proven. Some heap blobs place
   ISA beyond 2 KB (e.g. prolog at `0x328`/`0x370`), so any reader must scan.
3. **`gcn_header.zig` is misleading** for real blobs; callers should use
   `gcn_blob.zig` for shipped OrbShdr data.
4. Diagnostic scan fired at call 100; earlier heap blobs may not be loaded yet.
   Dumps are representative, not exhaustive.

## Skipped / not checked

- Did not decrypt/disassemble `libSceGnmDriver.prx` (not in extracted tree).
- Did not attempt GCN→SPIR-V translation (out of scope; another worktree
  `gcn-shader` is adding `gcn_decode`/`gcn_translate` that can consume
  `gcn_blob.isaBytes`).
