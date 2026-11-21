# PS4 GCN shader resource capture — report

**Status: COMPLETE.** All four tasks done, tested, committed. PS4-only, data-only;
no shared renderer path was modified.

- Worktree: `/home/reng/projects/ps5_zig_emu/.worktrees/gcn-resources` (branch
  `gcn-resources`, base `3309ec5`).
- New module: `src/ps4_mode/gcn_resources.zig`.
- Exported from `src/ps4_mode/root.zig`; test wired into `test-ps4mode`.
- Fixture reuse: `terraria_frame_test.zig::captured_dcb` made `pub` (one-word
  change, no duplication of the 790-dword array).

## Commits

- `bf5f030` — `feat(ps4): capture GCN USER_DATA resources from DCB SET_SH_REG packets`
  (3 files: new module + root.zig export + fixture visibility).

## What was built

- `capture(words: []const u32) Resources` — no allocator, fixed-capacity arrays.
  Walks PM4 Type-3 packets, handles opcode `0x76` (SET_SH_REG) as well as
  counting opcode `0x69` (SET_CONTEXT) and `0x79` (SET_UCONFIG) so callers see
  what the DCB actually contained.
- Per-stage 16-word USER_DATA rows plus per-word `written` flags:
  pixel base `0x00c`, vertex base `0x04c`, compute base `0x240`. The compute
  base was taken from `gpu.ShaderStage.userDataBase()` (`resources.zig:118`) —
  the real Terraria DCB writes three V# descriptors at `0x244/0x248/0x24c`
  immediately before a `DISPATCH_DIRECT`, which confirms that row is live.
- Typed bindings: `raw_address` (64-bit pointer pair), `constant_buffer` (V#),
  `sampled_image` (T#), `sampler` (S#). Each binding keeps its SH register
  offset, USER_DATA index and decoded descriptor (address, size/extent/format).
- `formatV`, `formatT`, `formatS`, `formatPointer` and a dispatching `format`
  helper decode GCN descriptors into `ResourceKind` + 40-bit base address.
  GCN encodings used (cross-checked against shadPS4 `AmdGpu::Buffer/Image` and
  the public GFX7/SI ISA):
  - V# base = word0 | ((word1 & 0xfff) << 32); stride = word1[29:16];
    records = word2; type = word3[31:30] must be 0.
  - T# base = (word0 | ((word1 & 0x3f) << 32)) << 8; extent/format/type in
    words 2/3; type = word3[31:28] must be >= 8. Pitch validated/derived via
    `image_layout.pitchValid` / `derivePitch`; tiling index mapped to
    `image_layout.Tiling`.
  - S# is a 4-dword sampler with no GPU address (V# tried first).
  - Pointer pair = low | (high & 0xfff) << 32.
- Exposes both the chronological binding trace (every descriptor write, 13 for
  Terraria) and the final settled USER_DATA rows, so a translator can use
  either view.

## Exact test output

`zig build test-ps4mode` — exit 0, no output (Zig prints only failures).

Direct module run (shows the new tests at positions 1-3):

```
$ ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16 \
    /home/reng/tools/zig-x86_64-linux-0.16.0/zig test src/ps4_mode/gcn_resources.zig
1/24 gcn_resources.test.Terraria DCB: recover PS/VS/CS USER_DATA descriptors from real SET_SH_REG packets...OK
2/24 gcn_resources.test.format helpers decode GCN V#/T#/S#/pointer descriptors...OK
3/24 gcn_resources.test.capture ignores SH packets outside USER_DATA rows and malformed packets...OK
4/24 image_layout.test.thin offsets stay within tile...OK
5/24 image_layout.test.pitch rules...OK
6/24 terraria_frame_test.test.Terraria DCB: guest colour target, draws and shader programs survive the PS4 path...OK
7/24 terraria_frame_test.test.NEGATIVE (missing capability): GCN shader words are not translated to SPIR-V; PS4 replay uses the probe fallback...OK
8/24 shader_binding.test.records shader pointers for the PS4 submit boundary...OK
9/24 pm4_sanitize.test.recovers draw behind an out-of-range GCN register packet...OK
10/24 pm4_sanitize.test.drops out-of-range shader and config writes, keeps valid ones...OK
11/24 pm4_sanitize.test.synthesizes missing PS4 render-target registers from the guest's CB base...OK
12/24 pm4_sanitize.test.colorTargetAddress recovers the guest base from CB_COLOR0_BASE...OK
13/24 pm4_sanitize.test.synthesizes PS/VS program registers from recorded PS4 shader pointers...OK
14/24 pm4_sanitize.test.no recorded shader programs injects nothing into a native stream...OK
15/24 pm4_sanitize.test.no CB base in the stream means no synthesized registers...OK
16/24 pm4_sanitize.test.skips garbage, reserved and truncated words without forwarding them...OK
17/24 hits.test.two records of one name report count 2, and reset clears it...OK
18/24 game_hook.test.configFromEnv: PS5_PS4_MODE=on enables compat, absent follows auto policy...OK
19/24 runtime.test.auto enables only ps4 titles...OK
20/24 runtime.test.explicit on/off override detection...OK
21/24 runtime.test.session retarget keeps policy...OK
22/24 detector.test.title id prefixes classify generations...OK
23/24 detector.test.elf object types classify generations...OK
24/24 detector.test.ps4 title id wins over mismatched elf type...OK
All 24 tests passed.
```

`zig build test` — exit 0 (full suite passed). Its log contains pre-existing
diagnostic lines such as `failed command: ./.zig-cache/.../test ...` and
`[spirv] lowering failed ...` emitted by unrelated tests that exercise error
paths; these are expected and are not failures (the build exit code is 0).

`zig fmt --check` on all three touched files — exit 0.

## What the real Terraria DCB actually contains (register dump summary)

Source: `/tmp/opencode/terraria-dcb.bin`, 3160 bytes / 790 dwords, first dword
`0xc0055800` (verbatim fixture reused from `terraria_frame_test.zig`).

Packet counts from `capture`: **13 SET_SH_REG (0x76)**, **2 SET_UCONFIG
(0x79)** (both write uconfig `0x242` = `0x13`), many SET_CONTEXT (0x69).
The DCB holds two repeated graphics blocks plus a compute dispatch; all 13
SET_SH_REG packets land inside a stage USER_DATA row, yielding **13 bindings**
(0 overflow). No SET_SH_REG writes the PS/VS program-address registers — those
are still synthesized by `pm4_sanitize` from HLE-recorded shader pointers.

| # | stage | SH reg | user idx | kind | decoded base / notes |
|---|-------|--------|----------|------|----------------------|
| 1 | CS | 0x248 | 8 | V# constant_buffer | `0x10_168c8000`, stride 4, 2,088,960 records — views the colour target as a buffer |
| 2 | CS | 0x244 | 4 | V# constant_buffer | `0x10_00000704`, stride 4, 1 record |
| 3 | CS | 0x24c | 12 | V# constant_buffer | `0x10_0000074c`, stride 16, 1 record |
| 4 | VS | 0x054 | 8 | V# constant_buffer | `0x10_1009cb60`, stride 16, 4 records (64 B) |
| 5 | PS | 0x018 | 12 | S# sampler | no address; raw0 `0x00fff000_00000092` |
| 6 | PS | 0x010 | 4 | T# sampled_image | `0x10_170c0000`, 684x480, type 9 (2D), tiling 13 (Thin1DThin), RGBA8 UNORM |
| 7 | VS | 0x04c | 0 | raw_address | `0x10_1009cbb0` (64-bit pointer pair) |
| 8 | VS | 0x04e | 2 | raw_address | `0x10_10000f5c` |
| 9 | VS | 0x054 | 8 | V# constant_buffer | `0x10_1009d0a4`, stride 16, 4 records (64 B) |
| 10 | PS | 0x018 | 12 | S# sampler | same as #5 |
| 11 | PS | 0x010 | 4 | T# sampled_image | `0x10_168c8000`, **1920x1080**, type 9, tiling 10 (Display2DThin), RGBA8 UNORM — the guest colour target sampled as a texture |
| 12 | VS | 0x04c | 0 | raw_address | `0x10_1009cbb0` |
| 13 | VS | 0x04e | 2 | raw_address | `0x10_10000f8c` |

Settled rows (last write wins): PS USER_DATA[4..11] = T# words of #11,
[12..15] = S# of #5; VS [0..1]/[2..3] = pointers #12/#13, [8..11] = V# of #9;
CS [4..7]/[8..11]/[12..15] = V#s #1/#2/#3. The 1920x1080 T# base
(`0x10_168c8000`) equals `CB_COLOR0_BASE (0x10168c80) << 8`, confirming the
GFX6/7 T# base encoding.

## Concerns / not checked

- **No renderer integration.** This delivers data only, as required. A future
  translator must map these bindings onto `gpu.ShaderBindings` /
  `GraphicsResources`; the S# raw bits and T# swizzle/format are exposed but
  not converted to Vulkan samplers/views here.
- **Descriptor classification relies on SET_SH_REG packet shape** (2 dwords =
  pointer, 4 = V#/S#, 8 = T#) plus validity checks. A GNM driver that splits
  one descriptor across multiple packets, or inlines resource-table pointers,
  would be misclassified. The settled USER_DATA rows are exposed so a
  shader-aware translator can reinterpret them; Terraria's capture does not
  exercise that case.
- **Compute USER_DATA base 0x240** is taken from the shared RDNA2-oriented
  `gpu.ShaderStage`; it matches this DCB empirically (V#s before
  `DISPATCH_DIRECT`) but is not independently verified against a GFX7 register
  header.
- **V#/S# disambiguation** uses "base >= 0x1000 and type == 0" as the V# test;
  a legitimate V# at a very low address would be read as a sampler. No such
  case appears in the capture.
- **Unchanged files:** `pm4_sanitize.zig`, `shader_binding.zig`,
  `gnm_compat.zig`, `src/gpu/**`, `src/vulkan/backend.zig` and shared HLE were
  not touched. No subagents dispatched. Runtime cost/perf was not measured
  (capture is a single linear scan of the DCB).
