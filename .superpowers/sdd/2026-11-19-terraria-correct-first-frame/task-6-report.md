# Task 6 report — correctness gate and live first-frame proof

Status: **BLOCKED** (the live gate's numeric criterion is not met; the frame is
real guest-sourced pixels, not the solid-color probe).

## 1. What was done

### TDD: the gate test (Step 1–3 of the brief)

Wrote the brief's gate test verbatim into `src/ps4_mode/terraria_frame_test.zig`
with no scaffolding. `zig build test-ps4mode` failed to compile (red):

```
src/ps4_mode/terraria_frame_test.zig:259:17: error: use of undeclared identifier 'capture'
```

Added the minimal scaffolding the verbatim test needs: imports/aliases for
`capture`, `translatedGraphicsFor`, `fragmentInputsFor`, `vertexDataSourceFor`,
`sampledImageUserIndexFor`; a private `program` pair with the real GCN blobs
registered in-test (so the gate is hermetic and not order-dependent on
`gcn_real_blob_test.zig`); and the `selectedTexture(res)` helper that reads the
decoded USER_DATA word pair and forms the 40-bit T# address exactly as
`gcn_resources.formatT` does. The test then passed (green):

```
$ zig build test-ps4mode     # exit 0
$ zig build test             # exit 0
```

The gate asserts all three capabilities: `translatedGraphicsFor(program) != null`,
`fragmentInputsFor(program).?.allocated != 0`, and
`vertexDataSourceFor(cap.draws[0]) != null`; plus per-draw texture selection via
`selectedTexture(draw0) != selectedTexture(draw1)` (resolves to 0x10170c0000 vs
0x10168c8000).

### Carry-over fix (authorized file `src/hle/libs/ps4_title_stubs.zig`)

Live draws were still falling back to the fixed-color probe. Diagnostics showed
three distinct causes, all fixed in the PS4-only registration path:

1. **Once-only, partial-pair registration.** `tryRegisterRealShaders` fired on
   the *first* shader-set import, when only one of VS/PS was bound, and keyed
   the translation to that partial pair. The draw queries
   `translatedGraphicsFor` with the fully populated `shader_binding.programs()`
   pair, so the registration was never found. Fixed by deferring until both
   pointers are nonzero and keying to the exact bound pair.

2. **No retry after guest rebinds.** Terraria binds several different program
   pairs during startup (0x1000000a88/aa4 → 0x1000400a40/a5c →
   0x1000000a40/a5c …). A single `real_shaders_attempted` flag meant later
   pairs never got a registration. Replaced with atomic (vertex,pixel) key
   tracking so each newly bound pair gets registered once; PS5/native code is
   untouched.

3. **Wrong PS candidate / stage classification.** The scan locked in the first
   pixel blob (0x50a820) whose EXP profile cannot translate with the real VS
   (0x50adbc → `UnsupportedInstruction`), and the only vertex blob by EXP
   (0x50ac44) was skipped. Restored EXP-target stage inference (the header
   stage field disagrees with the ISA for Terraria's real VS/PS), collect all
   VS/PS candidates, and try each PS until the pair both translates *and*
   yields a decodable sampled-image USER_DATA slot. The winning pair is
   VS@0x50ac44 / PS@0x50adbc — exactly the pair the hermetic tests use.

After the fix, live draws use real translated SPIR-V (first draw compiled
`vs_words=524 ps_words=698`, vs. the probe's 143/74) and the translated PS's
sampled image is staged thousands of times (`[ps4] sampled image @0x10168c8000
1920x1080 -> binding 1 element 1`).

## 2. Live verification (Step 4 — exact brief command, three runs)

All three runs: exit 124 (expected timeout), `out/first-frame.ppm` present
(6,220,817 bytes), real shader compiled, sampled image staged. Histograms are
materially identical across runs.

Run 1 — `/tmp/opencode/first-frame-run-1.log` — 31,249 image-staging lines:

```
       2072615: (0.00279076,0.00268897,0.00400741) #000000 srgb(0.00109442%,0.0010545%,0.00157153%)
           357: (13.6557,1.77049,19.1311) #0E0213 srgb(5.35519%,0.694311%,7.50241%)
            96: (1.57732,3.86598,129.557) #020482 srgb(0.618557%,1.51607%,50.8065%)
            83: (249.571,7.76623,7.03896) #FA0807 srgb(97.8711%,3.04558%,2.76038%)
            63: (89.5172,106.172,103.603) #5A6A68 srgb(35.1048%,41.6362%,40.6288%)
            61: (117.169,13.1525,133.39) #750D85 srgb(45.9488%,5.15786%,52.3097%)
            58: (7.17241,3.56897,253.138) #0704FD srgb(2.81271%,1.39959%,99.2698%)
            50: (177.232,43.6429,18.5357) #B12C13 srgb(69.5028%,17.1148%,7.26891%)
            41: (4.05,2.45,86.15) #040256 srgb(1.58824%,0.960784%,33.7843%)
            41: (18.8182,218.152,196.515) #13DAC5 srgb(7.37968%,85.5496%,77.0648%)
            32: (63.1818,211.242,15.2727) #3FD30F srgb(24.7772%,82.8402%,5.9893%)
            29: (91.825,49.075,246.275) #5C31F6 srgb(36.0098%,19.2451%,96.5784%)
            27: (251.893,5.71429,224.286) #FC06E0 srgb(98.7815%,2.2409%,87.9552%)
            25: (0,0,160) #0000A0 srgb(0,0,160)
            16: (189.889,187.944,129.556) #BEBC82 srgb(74.4662%,73.7037%,50.8061%)
             6: (209.5,1.33333,0.5) #D20101 srgb(82.1569%,0.522876%,0.196078%)
```

Run 2 — `/tmp/opencode/first-frame-run-2.log` — 30,259 image-staging lines:
histogram byte-for-byte identical to Run 1 (same 16 entries and counts listed
above).

Run 3 — `/tmp/opencode/first-frame-run-3.log` — 28,814 image-staging lines:
histogram byte-for-byte identical to Run 1 (same 16 entries and counts listed
above).

### Gate evaluation (FAILED)

- 8 distinct colors with ≥ 100 px each: **FAIL** — only one non-black color
  reaches 100 px (357); the rest are 96, 83, 63, 61, 58, 50, 41, …
- No single color > 90% of non-black pixels: **PASS** — 357 / ~985 non-black
  ≈ 36%.

The frame is **not** a solid-color probe (252 unique colors, real texture
samples), but it does not meet the brief's numeric gate, so success is not
claimed.

Pixel analysis of `out/first-frame.ppm` (P6, 1920×1080): 252 unique colors,
~1,507 non-black texels (sum RGB > 12), all confined to a 3-pixel-tall band at
rows 595–597 spanning x=0..1862. This is the state of the guest triangle output
from earlier tasks, not a full Terraria scene.

### Window capture

- `DISPLAY=:0.0 xdotool search --name 'Vulkan guest output'` → `52428801`
- `xprop -id 52428801 _NET_WM_STATE` →
  `_NET_WM_STATE_MAXIMIZED_HORZ, _NET_WM_STATE_MAXIMIZED_VERT,
  _NET_WM_STATE_FOCUSED` (no HIDDEN — mapped).
- Saved `/tmp/opencode/correct-first-frame.png` (7,410 bytes, consistent with
  the mostly-black thin-line frame).
- Terraria was left running live on DISPLAY=:0.0 (PID 334994).

## 3. Verification summary

- `zig build test-ps4mode` → PASS including the new gate.
- `zig build test` → exit 0.
- `zig build build-game-run` → exit 0.
- Three live runs: materially identical multi-colored (never solid-color)
  first frames; gate's 8-color/100-px sub-criterion not met.

## 4. Concerns / why BLOCKED

- The real translated shader is definitely active and stages the guest texture,
  but the first frame collapses to a 3-row horizontal line. This matches the
  documented residuals of Tasks 3–4 (UV interpolation via VS PARAM0 into a
  Location-0 input is guest-sourced but not normalized; guest VS vector math is
  unrecovered), not a Task 6 registration fault.
- The gate as specified cannot be satisfied without reworking geometry/UV
  recovery in earlier-task code (`src/ps4_mode/gcn_decode.zig` /
  `gcn_translate.zig` / rdna2 writer), which is outside this task's authorized
  files and the "no src/gpu/** edits" constraint.
- `registered_vertex`/`registered_pixel` are written non-atomically with the
  subsequent registration; concurrent set-shader calls could double-register
  the same pair, which is harmless because the translator registry is
  internally locked.
- Live window capture shows a mapped, focused window; its content is the same
  thin-line frame.

---

## Re-dispatch after BLOCK — real VS decode and POS0 repair

### 1. Word-by-word decode of the real Terraria VS ISA

ISA = the 16 dwords embedded as `ps_words` in `gcn_real_blob_test.zig` (guest
0x50ac44, OrbShdr header calls it `pix_clear_constants`, stage field 12). Its
EXP target 0x0c/0x20 makes it the VS; the other blob (`vs_words`, 22 dwords,
guest 0x50adbc, header stage 8) exports MRT0 and samples an image, i.e. the PS.
The EXP decode is authoritative; the OrbShdr header stage field is inverted for
both blobs.

Microcode field layouts (AMD GCN3 ISA, Table 6.1 and microcode-format table):

- VOP2: bit31=0, OP[30:25], VDST[24:17], VSRC1[16:9], SRC0[8:0].
- VOP1: bits[31:25]=0b0111111, VDST[24:17], OP[16:9], SRC0[8:0].
- SOP1: bits[31:23]=0b101111101, SDST[22:16], OP[15:8], SSRC0[7:0].
- EXP: bits[31:26]=0b111110, DONE[11], VM[10], TARGET[9:4], ENABLE[3:0];
  second dword holds four 8-bit VGPR source indices.
- SOPP: bits[31:23]=0b101111111, OP[22:16], SIMM[15:0].

SRC0 operand codes are **not SGPR numbers** above 101: 128=0, 129..192=+1..+64,
193..208=-1..-16, 240=0.5, 242=1.0, 255=literal, 256..511=VGPR0..255.
VOP2/VOP1 opcode numbers (GCN 1.0/1.1): 0x1a=v_lshlrev_b32, 0x1b=v_and_b32,
0x25=v_add_i32, VOP1 0x01=v_mov_b32, VOP1 0x05=**v_cvt_f32_i32** (signed —
the decoder's comment calling it `v_cvt_f32_u32` is wrong; unsigned is 0x06).

| # | word | family / opcode | decoded operands | semantics |
|---|------|-----------------|------------------|-----------|
| 0 | `0xbeeb03ff` | SOP1 0x03 `s_mov_b32` | SDST=107, SSRC0=255 literal | OrbShdr ISA prolog marker; decoder reads literal 0x7 from word 1 |
| 1 | `0x00000007` | literal | `0x7` | literal operand of word 0 |
| 2 | `0x36020081` | VOP2 0x1b `v_and_b32` | VDST=v1, SRC0=129(+1), VSRC1=v0 | `v1 = 1 & v0` |
| 3 | `0x34020281` | VOP2 0x1a `v_lshlrev_b32` | VDST=v1, SRC0=129(+1), VSRC1=v1 | `v1 = v1 << 1` |
| 4 | `0x360000c2` | VOP2 0x1b `v_and_b32` | VDST=v0, SRC0=194(-2), VSRC1=v0 | `v0 = -2 & v0` (clear bit 0) |
| 5 | `0x4a0202c1` | VOP2 0x25 `v_add_i32` | VDST=v1, SRC0=193(-1), VSRC1=v1, carries to VCC | `v1 = -1 + v1` |
| 6 | `0x4a0000c1` | VOP2 0x25 `v_add_i32` | VDST=v0, SRC0=193(-1), VSRC1=v0 | `v0 = -1 + v0` |
| 7 | `0x7e020b01` | VOP1 0x05 `v_cvt_f32_i32` | VDST=v1, SRC0=257(v1) | `v1 = (float)(int32)v1` |
| 8 | `0x7e000b00` | VOP1 0x05 `v_cvt_f32_i32` | VDST=v0, SRC0=256(v0) | `v0 = (float)(int32)v0` |
| 9 | `0x7e040280` | VOP1 0x01 `v_mov_b32` | VDST=v2, SRC0=128(0) | `v2 = 0.0` (POS0.z) |
| 10 | `0x7e0602f2` | VOP1 0x01 `v_mov_b32` | VDST=v3, SRC0=242(1.0) | `v3 = 1.0` (POS0.w) |
| 11/12 | `0xf80008cf` / `0x03020001` | EXP target 0x0c POS0, EN=0xf, DONE=1 | src = (v1,v0,v2,v3) | `POS0 = (v1, v0, 0, 1)` |
| 13/14 | `0xf800020f` / `0x03030303` | EXP target 0x20 PARAM0, EN=0xf | src = (v3,v3,v3,v3) | `PARAM0 = (1,1,1,1)` |
| 15 | `0xbf810000` | SOPP 0x01 `s_endpgm` | SIMM=0 | end |

**Current decoder mishandling.** In `gcn_decode.Iterator.next`, `is_noop`
lowers VOP2 opcodes 0x1a, 0x1b, 0x25 and VOP1 opcode 0x05 to `s_nop`. That is
7 of the 9 real instructions in this VS (words 2–8). The prolog word 0 is read
as `s_mov_b32 s107, 7`; words 9–10 decode correctly. Additionally,
`decodeVertexToRdna2` injects a guessed MUBUF (`v0..v3 <- V# [v4]`) immediately
before POS0, overwriting exactly the VGPRs the real program computes, and
`buildOptions` seeds the VertexIndex built-in into v4 although the real ISA
reads v0.

**Where POS0 x/y come from.** Not a memory load: the real VS derives them from
the per-vertex index in v0 using inline constants only:

```
v1 = ((v0 & 1) << 1) - 1     // x: -1 for even index, +1 for odd
v0 = (v0 & -2) - 1           // y: -1 for indices 0/1, +1 for 2/3
x = (float)(int32)v1; y = (float)(int32)v0; z = 0; w = 1
```

i.e. a fullscreen quad corner generator (indices 0..3 → (-1,-1),(1,-1),
(-1,1),(1,1)). No SMRD, no V# fetch, no USER_DATA scalar is involved in POS0.
The injected MUBUF is therefore both unnecessary and harmful.

### 2. Implementation (PS4-only files)

TDD red first: a new hermetic test asserted the real VS decodes to
`v_and_b32, v_lshlrev_b32, v_and_b32, v_add_i32, v_add_i32, v_cvt_f32_i32,
v_cvt_f32_i32, v_mov_b32, v_mov_b32` (not s_nop) and that no memory instruction
appears in the normalized program; it failed to compile because the tags did
not exist.

Changes made:

- `src/ps4_mode/gcn_decode.zig`: added `v_and_b32`, `v_lshlrev_b32`,
  `v_add_i32`, `v_cvt_f32_i32` tags/payloads. Removed VOP2 0x1a/0x1b/0x25 and
  VOP1 0x05 from the `is_noop` list (only 0x2f packed-half convert still
  lowers to nop). GCN `v_lshlrev_b32` is normalized to RDNA2 VOP3 `v_lshl_b32`
  (id 0x119) with swapped operands so the 9-bit inline shift constant survives
  the 8-bit VOP2 src1 field; one guest word still advances the iterator by one.
  `decodeVertexToRdna2` no longer injects the guessed MUBUF — it is now a thin
  alias of `decodeToRdna2`.
- `src/ps4_mode/gcn_translate.zig`: the Terraria VS now seeds the VertexIndex
  built-in into **v0** (the register its ISA actually reads) instead of v4.
  No `src/gpu/**` or shared rdna2 writer changes; PS5/native paths untouched.
- `src/ps4_mode/gcn_real_blob_test.zig`: replaced the two stale MUBUF-based
  assertions with checks that the real ISA decodes to the nine arithmetic
  instructions, that no mubuf/smem instruction appears, and that the normalized
  program contains the expected `v_and_b32 x2 / v_lshl_b32 x1 / v_add_nc_u32 x2 /
  v_cvt_f32_i32 x2` sequence plus the VertexIndex built-in.

SPIR-V proof (dumped via a temporary test, then removed): the vertex module now
contains `OpLoad %gl_VertexIndex`, `OpBitwiseAnd` with 1 and 0xfffffffe,
`OpShiftLeftLogical` by 1, two `OpIAdd` with 0xffffffff (-1), two
`OpConvertSToF`, and `OpStore %gl_Position` of `(-1..1, -1..1, 0, 1)` — the
correct fullscreen-quad corner generator. No storage-buffer load remains.

### 3. Verification

- `zig build test-ps4mode` → PASS (66/66).
- `zig build test` → exit 0.
- `zig build build-game-run` → exit 0.
- Exact task-6 brief command, three runs (logs
  `/tmp/opencode/re-dispatch-run-{1,2,3}.log`), Terraria killed beforehand:
  exit 124 each, `out/first-frame.ppm` present (6,220,817 bytes), first draw
  compiles `vs_words=264 ps_words=698` (was 524/698 with the guessed MUBUF).
  All three histograms are byte-identical:

```
       2072615: (0.00,0.00,0.00) #000000  (quantized black)
           357: (13.66,1.77,19.13) #0E0213
            96: (1.58,3.87,129.56) #020482
            83: (249.57,7.77,7.04) #FA0807
            63: (89.52,106.17,103.60) #5A6A68
            61: (117.17,13.15,133.39) #750D85
            58: (7.17,3.57,253.14) #0704FD
            50: (177.23,43.64,18.54) #B12C13
            41: (4.05,2.45,86.15) #040256
            41: (18.82,218.15,196.52) #13DAC5
            32: (63.18,211.24,15.27) #3FD30F
            29: (91.83,49.08,246.28) #5C31F6
            27: (251.89,5.71,224.29) #FC06E0
            25: (0,0,160) #0000A0
            16: (189.89,187.94,129.56) #BEBC82
             6: (209.5,1.33,0.5) #D20101
```

Gate still **FAILS**: one non-black color ≥ 100 px (357), need ≥ 8.

### 4. Exact reason for BLOCK (not a geometry failure any more)

`first graphics draw: readback colored_pixels=0` both before and after the VS
repair. The VS is now correct (fullscreen quad, no guessed fetch), but the PS
produces black because its three SMRD constant loads have no real guest source:

- PS word 4 `s_load_dwordx4 s0, s[2:3]` — pixel USER_DATA[2:3] are **0/0** in
  the captured DCB (only indices 4,6,8..15 are written), so the constant-buffer
  pointer is null;
- PS words 6/7 `s_buffer_load_dwordx4` at offsets 4/0 read from the descriptor
  the first load was supposed to produce.

`ps4GraphicsScalars` in `src/vulkan/backend.zig` therefore still groups those
slots by producer PC and supplies heuristic values (vertex V# words, 0 origin,
0.25 steps) instead of real constant bytes. The sampled image is staged, but
the computed sample coordinate resolves to a black texel; the thin 3-row band
in `out/first-frame.ppm` is the guest's own color-target content, not our draw.
Fixing this requires recovering the real PS constant buffer (or its true
USER_DATA binding) — data the captured DCB does not contain — which would mean
fabricating UV constants, explicitly forbidden. The gate is not relaxed.

---

## Constant-source investigation (second re-dispatch)

### Instrumentation (all temporary diagnostics reverted before commit)

Placed `[ps4diag]` prints in `gcn_resources.capture` (one line per submitted
DCB: settled pixel USER_DATA[0..15], per-draw snapshot pxUD[2], all classified
descriptors), in `backend.zig ps4GraphicsScalars` (per-draw pixel program pair
and every scalar register/value/producer PC), and one-shot guest-memory reads
through `self.guest_memory.read` around the PS constant pointer and derived V#
base. Ran the exact live environment for 25 s with this instrumentation.

### Exact scan evidence

- **3,088 DCBs** captured in 25 s. **1,706** had nonzero settled pixel
  USER_DATA[2:3]. Distinct pairs (count): `1000104c/10` (755), `104600f0/10`
  (755), `10460120/10` (98), `1000107c/10` (98) — i.e. real 64-bit pointers
  `0x101000104c`, `0x10104600f0`, `0x10460120`-with-high-`0x10`,
  `0x101000107c`. The sampled image T# at pixel USER_DATA[4] is always
  `0x10168c80` → `0x10168c8000`; sampler at [12] is `0x92`.
- The 1,176-word DCBs (8 draws each) carry the pointer in **per-draw snapshots
  too**: e.g. `snapPxUD2 = 0 0 10000fec 10000fec 1000107c 1000107c 1000107c
  1000107c`; bindings include `PS[2]=raw_address@0x101000104c`. So the real
  constant pointer is genuinely present in the guest stream — the earlier
  "absent" conclusion (based only on the 790-word hermetic setup DCB) was
  wrong.
- Guest memory at `0x101000104c` at the first draw that bound it:
  `1026315b a00000 ff 94d00f2e 1fe000 0 0 0 92 fff000 5000000 0 108c0540
  180010 4 2005f22c` — a real T#-shaped descriptor (base `0x1026315b00` after
  the GCN `<<8`, type 9, width 256). The raw V# interpretation
  (`0x1026315b | (word1&0xfff)<<32 = 0x1026315b`) was **not** guest-readable;
  the 256-byte-shifted base is a texture address.
- At the **very first draw** (the one that produces `out/first-frame.ppm`),
  guest memory at `0x101000104c` is **all zeros**:
  `[ps4diag] early@0x101000104c: 0 0 0 0 0 0 0 0`. The guest writes that
  descriptor only later, when it switches to the real draw DCBs.

### Root cause of "draws never see the pointer" — found and fixed

`gcn_resources.publish()` dropped the **oldest** capture on ring overflow and
reset `capture_draw_cursor = 0`. With submits outpacing draws, every draw
re-read snapshot[0] of the head capture (the early setup DCB, pxUD[2]=0), so
the real constant pointer in later DCBs was never bound. Changed the ring-full
policy to drop the **new** capture instead. After the fix, 329 / 2,000 sampled
draws had nonzero pxUD[2] (before: 0 / 2,000).

### Real fix retained

- `gcn_resources.zig`: ring-full drops the new capture (above).
- `gcn_translate.zig`: new `fillPsConstantScalars(reader, ctx, USER_DATA,
  slots, values)` reads the PS's SMRD values from guest bytes: 16 bytes at the
  pointer for `s_load_dwordx4 s0,s[2:3]`, then offsets 4 and 0 of the derived
  descriptor base for the two `s_buffer_load_dwordx4`; entry-time slots still
  come from USER_DATA. Unreadable ranges leave zero.
- `backend.zig`: `ps4GraphicsScalars` now takes `GuestMemory` and uses the
  guest-sourced values when the pixel USER_DATA pointer is bound; the heuristic
  V#/0/0.25 fallback remains only for the first-frame case with no pointer.
- `gcn_real_blob_test.zig`: test with a fake guest memory asserting the four
  SMRD slot values are read from `0x101000104c` (the address found above).

### Live result (exact brief command, 3 runs, after the fix)

All three runs: exit 124, PPM present, first draw `vs=264/ps=698`,
`first graphics draw: readback colored_pixels=0`, max flip colored pixels 1,937.
Histograms byte-identical to the prior BLOCKED runs (one non-black color ≥100
px = 357, need ≥8). **Gate still FAILS.**

Reason: the first frame's own DCB has pixel USER_DATA[2:3] = 0/0 and the
constant descriptor at the would-be address is still zero at that instant.
Feeding the real data found later would require reading ahead of the guest's
own writes, i.e. fabricating UV constants for the first frame — forbidden.
The gate was not relaxed.
