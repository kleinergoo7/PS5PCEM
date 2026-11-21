# PS4 GCN → shared Vulkan renderer: receiving-end integration plan

**Status: INVESTIGATION COMPLETE (read-only).** No source files were edited and no
commits/subagents were made. All findings are anchored to
`/home/reng/projects/ps5_zig_emu/.worktrees/gcn-integration` (base `3dadccb`); the
main checkout is at the same commit. Line numbers are from that tree.

**Scope.** This report covers the *receiving end* only: how the first PS4 graphics
draw reaches the shared Vulkan backend, why it currently replays fixed-color
SPIR-V, the smallest PS4-gated interface a GCN→SPIR-V translator must implement,
the non-ISA blockers, and how to keep all shared changes PS4-gated with tests.
The GCN decoder itself is out of scope (other agents).

---

## Task 1 — Exact Vulkan backend path for the first graphics draw

### 1.1 Entry point and the PS4 gate

- `src/vulkan/backend.zig:45` — `pub export var ps4_compat_enabled: bool = false;`
  The comment at `:43-44` states every use below is PS4-gated so the PS5 path is
  unchanged. Set only at `src/game_run.zig:636` when a PS4 title is detected.
- `backend.zig:41381` `dcbDraw(context, state, packet)` is the graphics-packet
  callback. At `:41399-41401` it computes:
  - `vertex_stage = graphicsVertexStage(state)` (`:41071`, scans `.vertex`,
    `.export_shader`, `.geometry` for a bound program address),
  - `has_vertex = vertex_stage != null`,
  - `has_fragment = ShaderStage.pixel.programAddress(state) != null`.
- `backend.zig:41082-41086` `wantsPs4FixedColorDraw(state)`:
  ```zig
  fn wantsPs4FixedColorDraw(state: *const gpu.State) bool {
      if (!ps4_compat_enabled) return false;
      return graphicsVertexStage(state) != null and
          gpu.resources.ShaderStage.pixel.programAddress(state) != null;
  }
  ```
  It is computed at `:41416`. At `:41417` draws with no programs are skipped
  unless the graphics probe or `ps4_fixed_color` is active.
- `backend.zig:41620-41634` is the PS4 branch: it calls
  `self.drawPs4FixedColor(state, draw)` for each decoded draw, bumps
  `guest_graphics_draws`/`translated_draws`, and `continue`s — so the native
  `drawGuestGraphics` path is never entered in PS4 mode.
- `backend.zig:41682` is the native path for PS5:
  `self.drawGuestGraphics(state, draw, vertex_stage.?, null)`.

### 1.2 Why PS4 draws look like `vtx=false ps=null` and how the fallback substitutes shader words

- The PS4 GNM shader-set imports (`sceGnmSetVsShader` / `sceGnmSetPsShader`)
  were originally no-op stubs. `src/ps4_mode/shader_binding.zig:19-37` now
  records the raw guest pointers (atomics), and
  `src/ps4_mode/pm4_sanitize.zig:161-181` `synthesizeShaderProgramRegs()` emits
  `SET_SH_REG` packets for PS (`0x008/0x009`) and VS (`0x048/0x049`). So by the
  time `dcbDraw` runs, the *registers* are non-null — which is exactly why
  `wantsPs4FixedColorDraw` returns true.
- The failure is on the *decode/translate* side, not the register side:
  `backend.zig:41078-41081` documents it — "GCN programs bound through the GNM
  shader-set imports cannot be decoded by the shared AGC path." The shared
  `analyzedProgram` (`backend.zig:16738/16747/16769`) calls
  `gpu.shader_analysis.decodeWithOptions` / `decodeBoundedWithOptions`, which
  decode RDNA2/AGC ISA. A GCN `OrbShdr` blob (`src/ps4_mode/gcn_header.zig:22-80`,
  magic `OrbShdr\0`, GCN stage enum) is not consumable, so the native path
  produces no `vs_words`/`ps_words` — i.e. `vtx=false ps=null` in the diagnostic
  sense (no decoded program / no translated module), forcing a fallback.
- `backend.zig:25751-25776` `drawPs4FixedColor()` is the substitution:
  ```zig
  const render_state = gpu.resources.decodeRenderState(state);
  // pick first active color target → guestColorTarget()
  try self.beginFrameDraw();
  try self.drawGraphicsShaders(
      &graphics_probe_vertex_spirv,     // 143 words
      &graphics_probe_fragment_spirv,   // 74 words
      &.{}, &.{},                        // NO vertex/fragment scalar specializations
      GraphicsPipelineState.default(guest_target.descriptor.width,
                                    guest_target.descriptor.height),
      guest_target, &.{}, null,
      false, false, false, draw,
  );
  ```
  The fixed-color shader arrays are `backend.zig:49283` (`graphics_probe_vertex_spirv`)
  and `:49316` (`graphics_probe_fragment_spirv`); their export is the constant
  `(1.0, 0.25, 0.1)` seen in `terraria-shader-report.md:24-26,39-41`. Note the two
  empty scalar slices and the `GraphicsPipelineState.default(...)` — the fallback
  deliberately discards all guest vertex/fragment state and texture bindings and
  paints the guest's own decoded 1920×1080 target through the normal
  materialization/readback path (`backend.zig:20304-20498`).

### 1.3 Native path — how real shaders are obtained and selected (PS5 reference)

For a PS5 draw, `drawGuestGraphics()` (`backend.zig:25920`) does the following;
this is the path the PS4 translator must feed:

1. **Program addresses** — `backend.zig:26310-26322`:
   `vertex_address = vertex_stage.programAddress(state)`,
   `fragment_address = ShaderStage.pixel.programAddress(state)` (both from
   SH registers `resources.zig:127-144`, read at `0x048/0x008`).
2. **Decode** — `backend.zig:26354-26374`: build `gpu.ShaderMemoryReader`
   (`backend.zig:625-660` `GuestMemory.read`), resolve optional
   `memory.shader_header` (`:26355-26362`), then
   `self.analyzedProgram(reader, address, header)` twice. This yields
   `vertex_analysis` / `fragment_analysis` (`gpu.ShaderAnalysis`, decoded
   instructions + IR). Header/byte-limit logic at `:3569` and `:16778-16806`.
3. **Bindings capture** — `backend.zig:26375-26389`:
   `gpu.ShaderBindings.capture(state, stage, header, reader)` for each stage
   (USER_DATA words, SRT address, direct pointers — `gpu.ShaderBindings`).
4. **Resources** — `backend.zig:26675-26702`:
   - `prepareGraphicsResources(fragment_bindings, reader, fragment_analysis, …)`
     → `GraphicsResources`: sampled images (T#/S#) as image views + samplers;
   - `appendGraphicsResources(… vertex_bindings …)` adds vertex-stage images;
   - `updateSampledImageDescriptors(...)` (`:29587`) writes descriptor arrays.
   - `prepareComputeResources` for fragment storage/constants (`:27244`) and
     vertex storage/attribute buffers (`:26811`).
   - Scalar provenance → `vertex_scalar_regs` / `fragment_scalar_regs`
     (`:26738-26789`), uploaded via `writeGraphicsScalarValues` (`:20317`,
     `:37863-37876`) into the dynamic-scalar SSBO.
5. **Fragment SPIR-V selection** — `backend.zig:27374-27422`:
   `fragment_lease = self.graphics_translations.acquirePrepared(allocator,
   &fragment_analysis.program, rdna2.spirv.Options{ .stage=.fragment,
   .scalar_registers=fragment_scalar_regs, .sampled_images=…,
   .storage_buffers=…, .parameter_mask=…, .color_export_*=… }, …)`.
   The final `fragment_words` are chosen at `:27661-27676`: diagnostic probes
   first, else `fragment_module.words`.
6. **Vertex SPIR-V selection** — `backend.zig:27683-27767`:
   `try_guest_vs = probe_parameter_mask == 0`; then
   `vertex_module_result = self.graphics_translations.acquirePrepared(...,
   &vertex_program, rdna2.spirv.Options{ .stage=.vertex, .vertex_index_vgpr=5,
   .storage_buffers=vertex_storage.mappings, .sampled_images=…,
   .parameter_mask=paired_parameter_mask, … }, …)`. Fallback built modules
   (`buildUnityUiVertexSpirv`, `buildFullscreenProbeVertexSpirv`, etc.) are
   selected at `:27709-27735`.
7. **Submit to shared draw** — `backend.zig:27848-27863`:
   `drawGraphicsShadersWithModules(vertex_module.words, fragment_words,
   vertex_scalar_regs[0..count], fragment_scalar_regs[0..count], pipeline_state,
   target, extra_colors, depth_plane, …, bind_descriptors, false, draw,
   .{ .vertex = vertex_lease, .fragment = fragment_lease })`.
8. **Pipeline + bind + draw** — `drawPersistentGraphicsShaders()`
   (`backend.zig:20098`), reached through `drawGraphicsShadersWithModules`
   (`:20617`, `:20633-20647`):
   - acquire/transition color target (`:20118-20146`);
   - index buffer upload (`:20148-20177`);
   - `getGraphicsPipeline(pass, native_state, vertex_words, fragment_words,
     modules)` (`:20304`, implementation `:16982-17064`);
   - scalar upload (`:20317`), render pass begin (`:20408-20410`);
   - `cmd_bind_descriptor_sets(... compute_pipeline_layout, 0, 1,
     &self.descriptor_set ...)` (`:20414-20427`) — **one shared descriptor set**;
   - `cmd_draw_indexed` / `cmd_draw` (`:20429-20454`);
   - mark target written + optional readback (`:20469-20498`).

**Vertex buffers / formats:** there is deliberately **no Vulkan vertex-input
path**. `createGraphicsPipeline` uses an empty
`vk.PipelineVertexInputStateCreateInfo{}` (`backend.zig:16612`) and there is no
`cmd_bind_vertex_buffers` in the graphics path. Vertex data is *pulled* by the
translated vertex shader from SSBOs in the shared descriptor set: the
`rdna2.spirv.StorageBufferBinding` entries (format `unified_format`,
`dst_select`, `stride`, `soffset_value`, `use_vertex_index` — `rdna2/spirv.zig:23-65`)
come from GCN V# registers decomposed in `prepareComputeResources` and the
helper tables `backend.zig:6186-6259` (`matchVertexAttribute` /
`takeNextVertexAttribute`, `maximum_vertex_attributes = 32` at `:5869`).
Formats are the guest unified FORMAT values already understood by the RDNA2
translator — no new Vulkan format mapping is needed if the GCN decoder emits
the same `StorageBufferBinding` shape.

**Textures / samplers:** `GraphicsResources` (`backend.zig:~4990-5010`) holds
`images`, `descriptors`, `mappings` (`rdna2.spirv.SampledImageBinding`,
`src/rdna2/spirv.zig:99-142`). `prepareGraphicsResources` resolves each GCN
T#/S# pair into a `gpu.ImageDescriptor` (address, width/height, pitch,
`unified_format`, `tile_mode`, `dst_select`), then
`updateSampledImageDescriptors` (`:29587`) creates/binds `vk` image views and
combined image/samplers into descriptor binding 1
(`sampled_image_2d_descriptor_binding`, plus 3D/cube/array/uint/sint variants —
`rdna2/spirv.zig:157-196`, layout `backend.zig:7600-7662`).

**Descriptor set / bindings layout** (all at `backend.zig`, one set, one layout
`compute_pipeline_layout` shared by compute *and* graphics):
- binding 0: storage buffer array `maximum_storage_descriptors`
  (`flushStorageDescriptors` `:29356-29380`, stage flags V|F|C);
- binding 1: combined image/sampler array (V|F|C);
- `2 .. 2+maximum_storage_images`: storage images (C|F);
- binding `dynamic_scalar_descriptor_binding = 2 + maximum_storage_images`
  (`:1362`): dynamic scalar SSBO (V|F|C), written by `writeGraphicsScalarValues`;
- plus 3D/cube/2D-array/GDS/comparison/packed-feedback/uint/sint bindings
  (`:1363-1371`, mirrored in `rdna2/spirv.zig:159-196` with static asserts at
  `backend.zig:1369-1371`).
The SPIR-V translator (RDNA2) already emits `OpDecorate ... Binding=<n>` for all
of these; a GCN translator must emit the *same* decorations for the shared
descriptor set to bind correctly.

---

## Task 2 — Smallest PS4-gated interface for a GCN→SPIR-V translator

The shared path already consumes exactly two immutable SPIR-V word slices plus
two small parallel metadata arrays; that is the natural seam. Reuse it rather
than inventing new Vulkan plumbing.

### 2.1 Data the translator must return (per draw, VS and PS)

This is precisely the argument set of `drawGraphicsShadersWithModules`
(`backend.zig:20617-20632`) / `getGraphicsPipeline` (`:16982`):

```zig
// In src/ps4_mode — PS4-only result of translating one bound GCN program pair.
pub const Ps4TranslatedGraphics = struct {
    vertex_words: []const u32,
    fragment_words: []const u32,
    // Optional cache-owned modules; pass through as GraphicsShaderModules to
    // avoid re-hashing/retaining raw words. null = backend retains a dup.
    vertex_module: ?spirv_cache.Lease = null,
    fragment_module: ?spirv_cache.Lease = null,
    // SGPR specializations; written into the dynamic-scalar SSBO by the
    // already-existing writeGraphicsScalarValues (backend.zig:37863).
    vertex_scalars: []const gpu.ShaderSpirvScalarRegister = &.{},
    fragment_scalars: []const gpu.ShaderSpirvScalarRegister = &.{},
};
```

If the translator wants the backend to build resources (recommended — do not
duplicate that work), it returns the *decoded program* + `ShaderBindings`
instead of raw words, and the existing resource path runs unchanged. The
minimal hand-off type is then:

```zig
// src/ps4_mode/gcn_translate.zig (new, PS4-only)
pub const Ps4GraphicsInput = struct {
    vertex_address: u64,     // SH 0x048/0x049, already synthesized
    fragment_address: u64,   // SH 0x008/0x009
    // The translator owns decoding GCN OrbShdr (gcn_header.zig) → an IR that
    // rdna2.spirv can emit from. It must produce the same shapes the shared
    // pipeline expects:
    vertex_program: rdna2.Program,
    fragment_program: rdna2.Program,
    vertex_bindings: gpu.ShaderBindings,
    fragment_bindings: gpu.ShaderBindings,
};
pub fn translateGraphics(
    allocator: std.mem.Allocator,
    input: Ps4GraphicsInput,
    // reuse the existing Options structs so binding numbers/exports match:
    vertex_options: rdna2.spirv.Options,
    fragment_options: rdna2.spirv.Options,
) !Ps4TranslatedGraphics;
```

Key requirement: the returned SPIR-V must use the **existing binding numbers**
(`rdna2/spirv.zig:157-196`) and the **same export/parameter ABI** (color export
mappings, `parameter_mask`, `vertex_index_vgpr`, dynamic scalar binding) that
`rdna2.spirv.Options` describes (`backend.zig:27374-27422` and `:27737-27767`).
If the GCN translator emits SPIR-V through `rdna2.spirv` (rather than its own
emitter), all of that is automatic — strongly preferred; this is why the
receiving interface is "hand back `rdna2.spirv.Options`-shaped input", not
"hand back arbitrary SPIR-V".

### 2.2 Concrete call site (PS4-gated, replaces `drawPs4FixedColor`)

Modify `backend.zig` so the PS4 branch at `:41620-41634` calls a new
`drawPs4Graphics` instead of `drawPs4FixedColor`. Inside it (replacing the body
at `:25751-25776`):

```zig
fn drawPs4Graphics(self: *Renderer, state: *const gpu.State, draw: GuestDraw) anyerror!void {
    const decoded = gpu.resources.decodeRenderState(state); // target discovery, same as today
    const target = /* first active guestColorTarget, as at :25753-25760 */;
    const input = ps4_gcn_translate.captureInput(self.allocator, state, decoded, target) catch
        return self.drawPs4FixedColor(state, draw);           // keep current fallback on failure
    defer input.deinit();

    // Reuse the shared resource pipeline exactly as drawGuestGraphics does.
    const gfx = try ps4_gcn_translate.translate(self.allocator, input, /* Options... */);
    defer if (gfx.vertex_module) |m| m.release();
    defer if (gfx.fragment_module) |m| m.release();

    try self.beginFrameDraw();
    try self.drawGraphicsShadersWithModules(
        gfx.vertex_words, gfx.fragment_words,
        gfx.vertex_scalars, gfx.fragment_scalars,
        GraphicsPipelineState.default(target.descriptor.width, target.descriptor.height),
        target, &.{}, null, false, true, false, draw,
        .{ .vertex = gfx.vertex_module, .fragment = gfx.fragment_module },
    );
}
```

Notes:
- `bind_graphics_descriptors = true` (the 5th-from-last `false` in today's
  fallback becomes `true`) so the single descriptor set is bound — see
  `backend.zig:20414`.
- Start with `GraphicsPipelineState.default(w,h)` as today; for fidelity, later
  call `guestGraphicsState(&decoded, color)` (`backend.zig:16367`) to honor
  guest viewport/scissor/cull, exactly like the native path (`:26340` region).
- Lifetime: SPIR-V words must outlive the draw (pipelines retain via
  `retainGraphicsWords` / module leases, `:16969-16979`); use `spirv_cache.Lease`
  (`translation_cache.zig:109-163`) so the existing cache/lifetime rules hold.
- Prefer wiring the translator into `graphics_translations.acquirePrepared`
  (`translation_cache.zig:273`) by supplying GCN-decoded `rdna2.Program` +
  `rdna2.spirv.Options`; then the entire `:27374`/`:27737` selection, caching,
  dump and pipeline path works unchanged and the interface collapses to
  "produce an `rdna2.Program` for VS/PS".

### 2.3 Where PS4 code injects it

- New PS4-only module `src/ps4_mode/gcn_translate.zig`, exported via
  `src/ps4_mode/root.zig` (`:1-70`).
- `src/vulkan/backend.zig` adds a single PS4-only `drawPs4Graphics` next to
  `drawPs4FixedColor` (`:25751`) and a new gate
  `wantsPs4RealShaderDraw(state)` next to `wantsPs4FixedColorDraw` (`:41082`):
  ```zig
  fn wantsPs4RealShaderDraw(state: *const gpu.State) bool {
      return ps4_compat_enabled and /* translator available */ and
          wantsPs4FixedColorDraw(state);
  }
  ```
  Selection at `:41620`: real draw when available, else keep fixed-color. Both
  gates return false when `ps4_compat_enabled == false`, so PS5 behavior is
  untouched.

---

## Task 3 — Blockers beyond shader ISA (ranked)

| # | Blocker | Shared mechanism to reuse | What PS4 code must supply | Risk |
|---|---------|---------------------------|---------------------------|------|
| 1 | **Resource discovery from GCN USER_DATA / V#/T#/S#** | `gpu.ShaderBindings.capture` (`backend.zig:26375`), `prepareGraphicsResources`/`appendGraphicsResources` (`:26675-26695`), `prepareComputeResources` (`:26811`,`:27244`), `GraphicsResources` + `ComputeResources` | Decode GCN `s#`/`v#` USER_DATA into the same `ShaderBindings` shape; T#/S# → `gpu.ImageDescriptor`, V# → `rdna2.spirv.StorageBufferBinding`. The `ShaderBindings` decode is RDNA2-specific (RSRC2 USER_SGPR count, `resources.zig:146-167`) and must be re-derived for GCN. | Highest — without correct bindings the real shader runs but samples/fetches garbage. |
| 2 | **Vertex format/layout from `SQ_VTX_ATTRIBUTE` registers** | Vertex pull via `StorageBufferBinding` (stride, `unified_format`, `dst_select`, `soffset_value`, `use_vertex_index`) — `spirv.zig:23-65`; helpers `backend.zig:6186-6259`; no Vulkan vertex-input path (`:16612`) | Decode GCN vertex attribute `SQ_VTX_ATTRIBUTE` (FORMAT, OFFSET, VB index, INSTANCE?) and the fetch shader's V# loads into those bindings; match the fetch-shader inlining convention (`backend.zig:26506-26522`). | High — wrong FORMAT/offset collapses geometry or swaps position/UV (see the Unity warning at `:27502-27510`). |
| 3 | **Texture resource descriptors (T#/S#) → image views/samplers** | `prepareGraphicsResources` + `updateSampledImageDescriptors` (`:26699`,`:29587`), `gpu.ImageDescriptor`, tiled formats via `src/ps4_mode/image_layout.zig` | Decode GCN T# (base address, size, format, swizzle, mip) and S# (filter/address modes) into `gpu.ImageDescriptor` + `rdna2.spirv.SampledImageBinding` (`spirv.zig:99-142`). PS4 thin/thick tiling already has `image_layout.zig`; ensure pitch/tile mode match `gpu.resources.decodeBufferDescriptor`-style expectations. | High — Terraria is sprite/texture heavy; wrong swizzle/tiling gives corrupted art. |
| 4 | **Constant buffers** | Scalar provenance + dynamic-scalar SSBO (`writeGraphicsScalarValues`, `:37863`) and storage buffers in binding 0; `mergeUserDataScalars` (`:26752`) | Decode GCN CB/USER_DATA into SGPR specializations or V# storage descriptors so `s_buffer`/`s_mrd` loads resolve. | Medium-high — shaders read matrices/palette constants; "identity" fallback at `:27285-27290` only saves Unity color scales. |
| 5 | **Draw topology & raster state** | `decodeDirectGuestDraw` (`:41192`), `expandRectangleListDraw` (`:41603`), `guestGraphicsState` (`:16367`), `decodeRenderState` (`resources.zig:665`), `getGraphicsPipeline` uses `pipeline_state.topology` (`:16614`) | GNM primitive type → `gpu.RenderState.primitive_type`; PS4 PM4 draw packets must survive `pm4_sanitize` (currently only register writes are sanitized; `gnm_packets.zig` has the neutral draw). Verify `VGT_DMA_INDEX_TYPE` → `draw.index_uint32` and `primitive_type` mapping. | Medium — wrong topology renders nothing/garbage; PS4 triangle-list + rectangle-list likely already covered by existing decode. |
| 6 | **Color export / parameter ABI into the fragment stage** | `rdna2.spirv.Options.color_export_mappings/locations/types`, `parameter_mask`, `fragment_input_controls` (`:27396-27421`) | Map GCN `EXP` instructions and PS interpolant (PARAM) semantics into these fields. If the GCN translator emits through `rdna2.spirv`, automatic. | Medium — wrong exports = black/incorrect colors; wrong param mask = VS/PS interface mismatch. |
| 7 | **Shader binary read path** | `GuestMemory.read` + `ShaderMemoryReader` (`:10507`,`:625-660`), optional `shader_header` (`:659`) | Ensure the synthesized 64-bit shader pointer from `shader_binding.zig` is a VA readable via `guest_memory.read`; PS4 `OrbShdr` header (`gcn_header.zig:69`) parsed before ISA decode. | Low — address is already recorded and readback machinery is real; just GCN-side parsing. |

**Recommended order:** 7 → 1 → 4 → 2/3 → 6 → 5. Get real words flowing with
correct resources (1-4), then fidelity (2,3,6,5).

---

## Task 4 — Shared renderer changes, gating, and tests

### 4.1 Shared code that must be touched (keep minimal)

1. `src/vulkan/backend.zig`
   - Add `wantsPs4RealShaderDraw` (next to `:41082`) and branch at `:41620`
     preferring `drawPs4Graphics` over `drawPs4FixedColor`; both are behind
     `ps4_compat_enabled`.
   - Add `drawPs4Graphics` (next to `:25751`), which calls the already-existing
     `drawGraphicsShadersWithModules` (`:20617`) / `getGraphicsPipeline`
     (`:16982`) / `drawPersistentGraphicsShaders` (`:20098`). **No changes to
     those shared functions are required** if the translator emits
     RDNA2-compatible `rdna2.spirv` output — that is the whole point of the
     seam.
2. `src/ps4_mode/{gcn_translate.zig (new), root.zig, shader_binding.zig,
   pm4_sanitize.zig}` — all PS4-only.
3. `src/game_run.zig:636` — unchanged (flag already set for PS4 titles only).

**Strict gating proof:** the only new statement reachable on the shared path is
inside `if (ps4_fixed_color) { ... }` at `:41620`, and both that gate and the new
one start with `if (!ps4_compat_enabled) return false;`. `ps4_compat_enabled`
defaults false (`:45`) and is set only in PS4-mode game-run (`:636`). Therefore
PS5 draws still flow through `:41682 → drawGuestGraphics` unchanged.

### 4.2 Tests to prove PS5 behavior unchanged

- Extend `backend.zig:49347` `"PS5 draws never take the PS4 fixed-color
  fallback"` with an assertion for the new gate: with `ps4_compat_enabled=false`,
  `wantsPs4RealShaderDraw(&state) == false` even with both program registers
  bound; with `true` it is true; with no programs it is false. This is the
  existing pattern and proves the shared path is untouched for PS5.
- Add PS4-module tests (`zig build test-ps4mode`):
  - `gcn_translate` decodes a minimal `OrbShdr` VS/PS fixture
    (`gcn_header.zig` helpers) and returns SPIR-V whose binding decorations
    equal `rdna2.spirv.*_descriptor_binding` constants (`spirv.zig:157-196`).
  - `shader_binding` + `pm4_sanitize` round-trip (already present at
    `:44-56`, `:336-353`) — extend to assert the synthesized addresses feed the
    translator input.
  - A `drawPs4Graphics` unit test that injects synthetic real words and checks
    `getGraphicsPipeline` cache receives them (mirror the existing
    `findGraphicsPipeline` tests at `backend.zig:1570-1650`).
- Integration verification (from `terraria-shader-report.md:9-16`): run
  `PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 … game-run --app0 …`
  and assert `out/first-frame.ppm` contains **more than two distinct colors**
  (the current fixed-color probe yields exactly `0,0,0` and `255,64,25`).
  Also assert the first-draw log shows `vs_words`/`ps_words` != 143/74.
- `zig build test` and `zig fmt --check` on touched files (same checks as
  `terraria-shader-report.md:63-70`).

---

## Key file:line references (quick index)

- PS4 flag & gate: `backend.zig:43-45`, `:41071`, `:41082-41086`, `:41416-41417`, `:41620-41634`, `game_run.zig:636`.
- PS4 fallback: `backend.zig:25748-25776` (`drawPs4FixedColor`), shader arrays `:49283`, `:49316`; evidence `terraria-shader-report.md:24-41`.
- Shader capture/synthesis (PS4): `ps4_mode/shader_binding.zig:19-37`, `ps4_mode/pm4_sanitize.zig:161-181`, `ps4_mode/gcn_header.zig:22-80`.
- Native draw entry: `backend.zig:25920` (`drawGuestGraphics`), program addresses `:26310-26322`, decode `:26354-26374`, bindings `:26375-26389`.
- Resource prep: `:26675-26702` (sampled images), `:26811` & `:27244` (vertex/fragment storage), scalar `:26738-26789`, `:20317`.
- SPIR-V translation & word selection: `:27374-27422` (PS), `:27661-27676` (`fragment_words`), `:27683-27767` (VS), `:27848-27863` (call).
- Pipeline/draw: `getGraphicsPipeline :16982-17064`; `createGraphicsPipeline :16550` with empty vertex input `:16612`, layout `:16706`; `drawPersistentGraphicsShaders :20098`, descriptor bind `:20414-20427`, draws `:20429-20454`.
- Descriptor set: constants `:1362-1371`, layout `:7600-7662`, `flushStorageDescriptors :29356`, `updateSampledImageDescriptors :29587`; RDNA2 binding numbers `rdna2/spirv.zig:157-196`, binding structs `:23-65`, `:99-142`; `rdna2/ir.zig:21-29`, `translation_cache.zig:109-163,273`.
- Existing gating test: `backend.zig:49347-49368`.

## Concerns / not checked

- **Not verified:** whether Terraria's GCN shader blobs are actually readable as
  `OrbShdr` at the VA recorded by `shader_binding.zig`, or whether the PS4
  loader strips the header (the pointer may point at raw ISA). `gcn_header.zig`
  parses a synthetic 32-byte prefix; real blob layout beyond that common subset
  is unverified. Confirm before designing the translator input.
- **Not verified:** GCN USER_DATA semantics vs RDNA2 `ShaderBindings.capture`
  (RSRC2 USER_SGPR count at `resources.zig:146-167`) — the PS4 gate currently
  synthesizes only program-address registers, **not** the USER_DATA window, so
  resource discovery (blocker #1) may need new PM4 synthesis in
  `pm4_sanitize.zig` in addition to the translator.
- **Not verified:** whether the GNM draw packets carry the same topology/index
  encoding the shared `decodeDirectGuestDraw` (`:41192`) expects; `pm4_sanitize`
  currently filters register writes only.
- **Not checked:** runtime cost. Per-draw GCN decode without a cache would be
  far slower than the RDNA2 `graphics_translations` path; the plan assumes the
  translator plugs into that cache (§2.2). If it cannot, add a PS4-only program
  cache keyed by shader address+bytes.
- **No changes made:** this was a read-only investigation; the report file is
  the only artifact written. The worktree and index are untouched.
