# GCN → SPIR-V translator feasibility (read-only study)

Date: 2026-11-19. Base requested: `3dadccb2f9675d13936923d19a2d1f03e2a1fa7a`.
Verified the key files at `.worktrees/gcn-integration` (still at `3dadccb`) are
byte-identical to the files inspected here. Note: the main worktree HEAD moved
to `3309ec5` during this study due to concurrent agent commits; the findings
below are for the `3dadccb` contents.

## Status / verdict

**FEASIBLE, with a small decoder front-end.** PS5PCEM already has a complete,
deterministic SPIR-V 1.5 writer that consumes *decoded instructions*, not decoded
RDNA2 binaries. A GCN shader only needs to be converted into the existing
`rdna2.Instruction` / `rdna2.Program` data structures; from there the SPIR-V
writer, CFG/control-flow lowering, descriptor layout, Vulkan pipeline path and
translation cache are reusable verbatim. The minimum new code is a GCN
instruction decoder plus a small word-reencoding layer and a PS4 options/resource
builder — roughly **1–1.5k LOC** for a sprite-shader subset, not a second
compiler backend.

Do **not** feed raw GCN words to `rdna2.decodeProgram`: the top-level encoding
and several opcode tables differ from GFX10, even where mnemonics match.

---

## 1. Reuse verdict

### Reuse verbatim (no change)

| Component | Where | Why it works |
|---|---|---|
| SPIR-V writer / encoder | `src/rdna2/spirv.zig` (18,698 lines) | `translate(allocator, *const Program, Options)` at :13881 and `translateBackend(..., BackendView, ...)` at :13870 consume `[]const instruction.Instruction`. They never re-read encoded words. The writer is a real builder (`Module.words: []u32`), not tied to AGC/RDNA2 binaries. |
| CFG construction + control-flow structuring/dispatcher | `src/rdna2/control_flow.zig`, used at `spirv.zig:14036`, `:14124` | Works purely from decoded instruction `pc`, `branch_target`, `opcode.isBranch()`. GCN SOPP branch immediates use the same dword→byte scaling (`scalar_alu.zig:404-405`: `offset = imm*4`, `target = pc+4+offset`). |
| Translation cache | `src/rdna2/translation_cache.zig` (`Cache.acquire`, keyed by code + decoded instructions + options) and `Renderer.graphics_translations` (`backend.zig:6843`) | A GCN-derived `rdna2.Program` with `code =` GCN words is a distinct key; the cache calls `translateProgramSpirvWithPipelineOptions` on miss. |
| Vulkan descriptor layout + binding numbers | `backend.zig:7600-7662` with asserts at :1370-1371 against `rdna2.spirv.sampled_image_2d_descriptor_binding` (1), storage images (3..34), etc. | The translator supplies `Options.sampled_images`/`storage_buffers` with matching `descriptor_index`; the host layout is unchanged. |
| Vertex-attribute lowering | `StorageBufferBinding` (`spirv.zig:23-65`: stride, unified_format, dst_select, add_thread_id, index_stride) and `buffer_load_format_*` handling in the writer | The instruction-level part is format-agnostic. Only the *metadata* source differs (see below). |
| Export lowering | `spirv.zig:13969-13985`: infers `parameter_mask` from `exp` target ≥ 0x20, `color_export_mask` from MRT0..7, depth from MRTZ | GCN VS `exp pos`/`exp param` and PS `exp mrt0` map directly. |
| PS4 blob header scaffolding | `src/ps4_mode/gcn_header.zig` | Fine as a *test* container (`parse`, `isaBytes`, stage labels). Treat the "OrbShdr" 32-byte prefix as unverified against real Terraria blobs. |

### Reuse after a small, local re-encoding (same `decode*` functions, normalized words)

| GCN family | Reuse path | Required transform |
|---|---|---|
| SOP2 / SOPP / SOPC | `scalar_alu.decodeSop2/decodeSopp/decodeSopc` | Word layout and opcode IDs are the same as RDNA2 (`s_add_u32`=0x00, `s_movk_i32`=0x00, `s_branch`=0x02, `s_cbranch_scc0/1`=4/5, `s_endpgm`=0x01). |
| SOP1 | `scalar_alu.decodeSop1` | Word layout identical; opcode IDs shifted: GCN `s_mov_b32`=0x00 vs RDNA2=0x03, GCN `s_mov_b64`=0x01 vs 0x04. Remap a handful of IDs. |
| SMEM (GCN SMRD) | `scalar_memory.decodeSmem` | GCN SMRD is **1 dword** (`s_load_dwordx4` opcode 0x02, `s_buffer_load_dwordx4` 0x0a); GFX10 SMEM is **2 dwords** with dst at word0[12:6], base at word0[5:0]*2, offset in word1. Re-encode. |
| MUBUF | `vector_memory.decodeMubuf` | Opcode IDs 0x00-0x03 (`buffer_load_format_x/xy/xyz/xyzw`) and word0 flag bits (O=12, I=13, G=14) match. Word1 is byte-permuted: GCN `[VADDR(31:24), VDATA(23:16), SRSRC(15:11), flags(10:8), SOFFSET(7:0)]` → RDNA2 `[SOFFSET(31:24), SRSRC(20:16), VDATA(15:8), VADDR(7:0)]`. |
| VOP2 / VOPC / VOP1 / VINTRP | `vector_alu.decodeVop2/decodeVopc/decodeVop1/decodeVintrp` | VINTRP is **identical** (word0[31:26]=0x32, OP at [17:16], ATTR at [15:10]). For GCN 1.0/1.1 the common VOP2 IDs already equal RDNA2 (`v_add_f32`=0x03, `v_sub_f32`=0x04, `v_subrev_f32`=0x05, `v_mul_f32`=0x08, `v_min_f32`=0x0f, `v_max_f32`=0x10, `v_mac_f32`=0x1f). GCN 1.2 shifts them (`v_add_f32`=0x01, `v_mul_f32`=0x05) — pick/verify the target generation. |
| VOP3 | `vector_alu.decodeVop3` | GCN 1.2 opcode bits [25:16] match RDNA2's `(word0>>16)&0x3ff`; `v_mad_f32`=0x141 in both. GCN 1.0/1.1 uses [25:17] (9 bits). |
| MIMG | `vector_memory.decodeMimg` | `image_sample` = opcode `0x20` and DMASK/SRSRC/SSAMP word1 layout match RDNA2's `0x20…0x3f → .image_sample` and `nibble = id & 7` flag decoding. Set `image_dimension = .dim_2d` manually (GCN has no DIM field; RDNA2 reads word0[5:3]=0 → 1D). |
| EXP | `vector_memory.decodeExp` | **Identical layout**: word0[31:26]=0x3E, TARGET [9:4], EN [3:0], COMPR bit10, DONE bit11, VM bit12; sources are word1 bytes. No re-encoding at all. |

### Must be new

1. **Correct GCN top-level decoder/dispatcher.** `ps4_mode/gcn_lower.zig:38-62`
   is scaffolding and is wrong for real GCN encodings. AMD GCN (GFX6/7) word0
   bits [31:26] are:
   VOP2 `0x00..0x1F` (bit31=0), VOPC `0x1F` (bits[31:25]=0b0111110), VOP1 `0x1F`
   (0b0111111), SOP2 `0x20..0x3F`, SOPK `0x2C/0x2D`, SOP1/SOPC/SOPP all `0x2F`
   (0xBE/0xBF), SMRD `0x30/0x31`, VINTRP `0x32`, VOP3 `0x34`, DS `0x36`,
   FLAT `0x37` (Sea Islands+), MUBUF `0x38`, MTBUF `0x3A`, MIMG `0x3C`,
   EXP `0x3E`. The scaffold instead lists VINTRP=0x0C, VOPC=0x0E, VOP1=0x0F,
   DS=0x35, FLAT=0x36, EXP=0x3B and collapses SOP1/SOPC/SOPP into `0x2F`.
   It also cannot distinguish VOP1 from VOPC or SOP1 from SOPP (needs bit25 /
   bits[29:23]). Replace its `classify` table, keep its `BufferDescriptor` /
   `ImageAccess` helpers.
2. **GCN `decodeProgram` driver**: word-index walk up to `s_endpgm` (GCN has no
   `s_code_end`), literal-constant handling (one trailing word), branch-target
   collection in byte PCs, and filling `Instruction.pc/word_count/raw`.
3. **PS4 resource/options builder**: map GCN T#/S# SGPR pairs (MIMG `src1/src2`)
   to `Options.sampled_images`, V# SGPRs (MUBUF `src1`) to
   `Options.storage_buffers`, VS PARAM exports to `parameter_mask`, PS EXP MRT
   to `color_export_mask`, and — hardest — `Options.fragment_inputs.allocated/
   enabled` from GNM `SPI_PS_INPUT_ADDR/ENA` (not present in the shader binary).
   `gpu/shaders.zig` does the equivalent job for AGC metadata and cannot be
   reused as-is.
4. **Integration** into the PS4-gated draw path (see §3).

---

## 2. Ranked minimal instruction subset (MonoGame/XNB sprite shader)

A typical Terraria PS4 sprite VS/PS compiles to: constant-buffer matrix loads →
vertex fetch → 4×4 position transform → `exp pos 0` + `exp param 0/1` (texcoord,
color); PS: `v_interp_*` → `image_sample` → `v_mul_f32` with vertex color →
`exp mrt0` → `s_endpgm`. Ranked by necessity:

| # | GCN mnemonic | Encoding / opcode (GCN 1.0/1.1 unless noted) | SPIR-V writer path | Notes |
|---|---|---|---|---|
| 1 | `s_endpgm` | SOPP 0xBF810000 (op 0x01) | program terminator / CFG root | Also `s_nop` 0xBF800000; `s_waitcnt` can be dropped or mapped. |
| 2 | `s_mov_b32` / `s_mov_b64` | SOP1 op 0x00 / 0x01 (RDNA2 0x03 / 0x04) | SGPR constants | Needs the SOP1 ID shift. |
| 3 | `s_load_dwordx4`, `s_buffer_load_dwordx4` | SMRD op 0x02 / 0x0a (1 dword) | `scalar_registers` / constant matrix | Re-encode to 2-dword GFX10 SMEM. `s_load_dwordx2`=0x01. |
| 4 | `buffer_load_format_xyzw` (and `..._xy`) | MUBUF 0xE0000000, op 0x03 / 0x01, idxen bit13 | `StorageBufferBinding` vertex fetch | Word1 swizzle; stride/format from V#. Fetch shaders may branch — #9 covers that. |
| 5 | `v_add_f32`, `v_sub_f32`, `v_mul_f32`, `v_mac_f32` | VOP2 op 0x03, 0x04, 0x08, 0x1f; `v_min_f32`=0x0f, `v_max_f32`=0x10 | `v_add_f32` etc. in `vector_alu.zig` | IDs already match RDNA2 for GCN 1.0/1.1. |
| 6 | `v_mov_b32` | VOP1 op 0x01 (bits[31:25]=0b0111111) | move | Same ID as RDNA2. |
| 7 | `image_sample` | MIMG 0xF0000000, op 0x20, DMASK bits[11:8], T#=word1[20:16]*4, S#=word1[25:21]*4 | `OpImageSampleImplicitLod` via `SampledImageBinding` | 0x21=CL, 0x22=D, 0x24=L, 0x25=B, 0x27=LZ; RDNA2 flag decoder handles the nibble. Force DIM=2D. |
| 8 | `exp` | 0xF8000000 base, TARGET[9:4], EN[3:0], DONE bit11; sources word1 bytes | VS POS/PARAM, PS MRT0 outputs | Decode verbatim with `decodeExp`. |
| 9 | `v_interp_p1_f32`, `v_interp_p2_f32`, `v_interp_mov_f32` | VINTRP 0xC8000000, op bits[17:16]=0/1/2, ATTR [15:10] | fragment inputs | Decode verbatim; `parameter_mask` inferred from ATTR at `spirv.zig:13987-13991`. Need `fragment_inputs` from GNM state. |
| 10 | `v_mad_f32` | VOP3 op 0x141 (`0xD1000000` class) | `v_mad_f32` | Only if compiler emits fused MAD instead of #5; VOP3 0x141 matches RDNA2. |
| 11 | `s_branch`, `s_cbranch_scc0/1` | SOPP ops 0x02, 0x04, 0x05; SIMM16 × 4 → byte target | structured selections / dispatcher | Occupies fetch-shader epilogues and alpha-test branches. |
| 12 | `v_cmp_*` + VOPC, `v_cmpx_*` | VOPC bits[31:25]=0b0111110, f32 ops 0x00-0x0f | EXEC/VCC predicates | Needed for alpha test / discard, not for the plain sprite case. |
| 13 | SOPK `s_waitcnt` / `s_cmpk_*` | SOPK 0xB0000000 class, op 0x17-0x1a (wait) | sync / scalar compare | GCN shaders insert these after SMEM/MUBUF; can be treated as no-ops for milestone 1. |

Explicitly **out of scope** for the first subset: DS/LDS, FLAT, GDS, atomics,
tessellation, `s_call_b64` / `s_setpc_b64`, VOP3P/packed f16, gather4, DPP/SDWA.

---

## 3. Concrete module plan, size, first milestone

All new files under `src/ps4_mode/`, exported from `src/ps4_mode/root.zig`
(alongside the existing `gcn_header` / `gcn_lower`). Keep `ps4_mode`
dependency-light in tests, but the translator module itself must import
`rdna2` (ok — it is already imported by `gpu/`/`vulkan/`).

| File | Contents | Est. LOC |
|---|---|---|
| `gcn_decode.zig` | Correct GCN family dispatch (replaces `gcn_lower.classify` usage), GCN→RDNA2 opcode remap tables, word re-encoders (SMRD, MUBUF, MIMG DIM), GCN `decodeProgram` returning `rdna2.Program`, plus unit tests for each family. Reuses `rdna2.scalar_alu/scalar_memory/vector_alu/vector_memory.decode*` after normalization. | 500–750 |
| `gcn_options.zig` | Build `rdna2.spirv.Options` from a GCN program + captured GNM state: `FragmentInputs`, `SampledImageBinding`/`StorageBufferBinding`, `parameter_mask`, `color_export_mask`, `scalar_registers`. Milestone-1 stub with fixed bindings: ~80 LOC. | 150–350 |
| `gcn_translate.zig` | Public `translateProgram(allocator, isa_bytes, stage, options) → rdna2.spirv.Module`; calls `gcn_decode.decodeProgram`, optional header parse via `gcn_header`, then `rdna2.translateSpirv` (or `translation_cache.Cache.acquire`). | 100–150 |
| `gcn_translate_test.zig` | Hand-assembled sprite VS/PS fixtures (GCN words), decode assertions, SPIR-V word assertions, optional `spirv-val`. | 200–300 |
| `backend.zig` patch | PS4-gated branch replacing the fixed-color path. | 40–80 |

**Total new: ~1.0–1.6k LOC**, vs ~20k LOC of SPIR-V writer + ~2.9k LOC of CFG/IR
reused untouched.

### Where the PS4-gated path calls it

`src/vulkan/backend.zig` already has the gate and the call site:

- `ps4_compat_enabled` at :43-45, set only by game-run when a PS4 title is detected.
- `wantsPs4FixedColorDraw(state)` at :41082, consumed at :41416 and :41620.
- `drawPs4FixedColor` at :25751 calls `drawGraphicsShaders(&graphics_probe_vertex_spirv, &graphics_probe_fragment_spirv, ..., draw, ...)`.

Milestone-1 wiring: keep the gate, replace `drawPs4FixedColor` with a
`drawPs4Translated` that reads the recorded VS/PS pointers from
`ps4_mode/shader_binding.programs()` (already synthesized into SH program
registers by `pm4_sanitize.synthesizeShaderProgramRegs`), translates them with
`gcn_translate.translateProgram`, and passes `module.words` into the same
`drawGraphicsShaders(...)` call. That bypasses the AGC `analyzedProgram` path
(`backend.zig:16738`, `:16769`) entirely, which is what currently rejects GCN
binaries. A later step can instead hook `decodeAnalyzedProgram` and populate a
`gpu.ShaderAnalysis` so the existing `graphics_translations` cache and resource
tracker apply.

### Testable first milestone

1. Unit test: a hand-encoded 8–12 instruction GCN pixel shader
   (`v_interp_p1/p2 → image_sample → v_mul_f32 → exp mrt0 → s_endpgm`) with a
   stub `Options` (one 2D sampled image binding, `color_export_mask = 1`,
   `fragment_inputs.allocated/enabled` for two interpolated inputs).
2. Assert `gcn_decode.decodeProgram` recognizes every instruction (no
   `.unsupported`), branch targets/word counts are right, and
   `rdna2.translateSpirv` returns a module containing `OpImageSampleImplicitLod`
   and a float multiply and no export opcodes (exports become stage outputs).
3. Optional integration check: feed `module.words` to `vkCreateShaderModule` in
   the existing smoke harness, or run `spirv-val` on a dumped `.spv`.
4. End-to-end goal for milestone 2: the PS4-gated draw produces a Terraria frame
   with more than two colors (the current fixed-color probe writes exactly
   `(1.0, 0.25, 0.1)`; see `terraria-shader-report.md`).

There is **no real Terraria GCN shader blob available** in the repo or in
`/tmp/opencode` — `gcn-vs.bin` / `gcn-ps.bin` there are 4096 zero bytes. The
first real-data check requires dumping the ISAs at the shader addresses recorded
by `sceGnmSet{Ps,Vs}Shader` from guest memory in a live run.

---

## 4. Existing caches / shortcuts

- `rdna2/translation_cache.zig` `Cache.acquire/acquirePrepared`: memoizes SPIR-V
  by program bytes + decoded instructions + options; `backend.zig:6843`
  `graphics_translations` (256 MiB default). Directly reusable once GCN decodes
  to `rdna2.Program`.
- `backend.zig:7600+` fixed Vulkan descriptor layout and `backend.zig:20599`
  `drawGraphicsShaders`: provides the plumbing for translated modules; no host
  changes needed beyond binding numbers already in `rdna2.spirv`.
- `vulkan/pipeline_cache_save.zig` + repo `vulkan_pipeline_cache.bin`: a driver
  pipeline-cache snapshot only; it cannot supply translations for GCN words.
- Fixed-color probe shader and its PS4 fallback (`backend.zig:25748/25751`,
  `41620`): this is the current *short-circuit* — it renders a frame but never
  executes Terraria's shaders. It is useful as the integration seam and as a
  differential baseline, not as a translation facility.
- `src/ps4_mode/gcn_header.zig` / `gcn_lower.zig`: scaffolding only; no decoder
  or cache exists today. `gpu/shaders.zig` (AGC metadata) and
  `gpu/shader_analysis.zig` are PS5-side and cannot parse PS4 blobs.

---

## Concerns / not checked

- `gcn_lower.classify`'s encoding table is materially wrong for real GCN and
  must be replaced, not extended; treating it as authoritative would misroute
  almost every instruction class.
- PS4 GPU generation is not confirmed from the code. GCN 1.0/1.1 vs 1.2 VOP2
  opcode tables differ (`v_add_f32` 0x03 vs 0x01); the decoder must either
  detect the generation from shader metadata or probe both tables.
- The "OrbShdr" header in `gcn_header.zig` is test-constructed; real Terraria
  shader blobs may be raw ISA with a different prefix. I did not disassemble a
  real Terraria shader because none is captured in the tree or `/tmp/opencode`.
- `Options.fragment_inputs` (SPI_PS_INPUT_ADDR/ENA) and GNM T#/S#/V# descriptor
  recovery from guest state are the largest unknown; a stub can produce correct
  SPIR-V structurally but wrong texture/attribute bindings until real GNM state
  is wired in.
- I did not compile or run anything (read-only), did not inspect the concurrent
  `gcn-abi` / `gcn-test` worktrees beyond status, and did not verify which GCN
  generation the shipped PS4 compiler targeted.
- The main worktree HEAD advanced to `3309ec5` during the study; re-check the
  cited line numbers if integrating after those concurrent commits.

**Skipped / not checked:** no SPIR-V validation run, no real GCN binary decode,
no GNM constant-buffer/vertex-table reverse engineering. Main risk: the PS4
shader binary may not use an "OrbShdr" prefix and may require GCN 1.2 opcode
tables; both need one live guest-memory dump to confirm.
