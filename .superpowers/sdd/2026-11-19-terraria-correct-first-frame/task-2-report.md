# Task 2 report — Program-keyed shader translation

Status: DONE

## What changed

- `src/ps4_mode/gcn_translate.zig`
  - Added `const gcn_resources = @import("gcn_resources.zig")` and
    `pub const ProgramPair = gcn_resources.ProgramPair;` (alias only — the single
    Task 1 definition is reused, not redefined).
  - Replaced the four stage globals (`vertex_isa/pixel_isa/vertex_spirv/pixel_spirv`,
    plus `vertex_slots/pixel_slots`) with a bounded `[8]ShaderTranslation`
    registry. Each entry is keyed by an exact `ProgramPair` and owns copies of
    both stage ISAs plus both stages' translated SPIR-V words and scalar slots.
    A round-robin `next_slot` recycles/evicts when all 8 entries are used;
    `deinit` frees every owned allocation on eviction and invalidation.
  - `registerShaderFor(program, stage, words)` inserts/refreshes one stage's ISA;
    when both stages of that pair are present it (re)translates the pair and
    stores both outputs. Re-registering either stage invalidates and rebuilds
    the pair. Translation of a single stage alone yields no usable output.
  - Added `translatedGraphicsFor(program)` (null unless both stages of the exact
    pair are present/translated) and `scalarSlotsFor(program, stage)`.
  - `registerShader`, `translatedGraphics`, `scalarSlots` remain as test-only
    helpers delegating to the `*For` API over a zero program pair. `lastDiagnostic`
    is unchanged (single global, cleared on every registration).
- `src/hle/libs/ps4_title_stubs.zig`: added `boundProgram()` converting
  `shader_binding.programs()` (`ShaderPrograms`) into a `ProgramPair`; both
  registration sites (`registerRealShaderAt` and `tryRegisterRealShaders`, the
  flow reached from `setPsShader`/`setVsShader`) now call
  `registerShaderFor(boundProgram(), stage, words)`.
- `src/vulkan/backend.zig`: `ps4GraphicsScalars` takes a `ProgramPair` and uses
  `scalarSlotsFor(program, stage)`; `drawPs4FixedColor` derives the pair from
  `shader_binding.programs()` and queries `translatedGraphicsFor(program)`,
  passing the same pair to both scalar fills. No PS5/native path touched;
  `src/gpu/**`, `gnm_compat.zig`, and `rdna2/spirv.zig` untouched.
- `src/ps4_mode/gcn_real_blob_test.zig`: added imports/aliases and the brief's
  `"program-keyed translation rejects mismatched pair"` test. The brief's
  `real_vs_isa`/`real_ps_isa` names were mapped to this file's actual embedded
  real-ISA arrays `vs_words`/`ps_words` (still verbatim real Terraria blobs);
  program addresses and assertions are exactly as specified.

## TDD evidence

- Wrote the test first; `zig build test-ps4mode` failed to compile with
  `root source file struct 'gcn_translate' has no member named 'ProgramPair'`
  (the first missing symbol in the chain `ProgramPair` → `registerShaderFor` →
  `translatedGraphicsFor`).
- Implemented the registry and the `*For` API; the new test and all existing
  tests pass.

## Tests (Zig 0.16 at /home/reng/tools/zig-x86_64-linux-0.16.0/zig)

- `zig build test-ps4mode`: exit 0 — `3/3 steps succeeded; 55/55 tests passed`
  (was 54 before this task).
- `zig build test`: exit 0 — `62/62 steps succeeded; 2102/2133 tests passed
  (31 skipped)`. The `failed command:` lines are the same pre-existing harness
  noise documented in the Task 1 report; no test binary reported a failure.
- Global Zig cache: 107 MB, under the 5 GB cap.

## Commit

`4034ccf feat(ps4): key translated shaders to the bound GNM program pair`
(only the four files in the brief's Files list).

## Concerns / not checked

- Runtime timing was not verified end-to-end. `tryRegisterRealShaders` is still
  once-only (`real_shaders_attempted`) and runs on the *first* shader-set import,
  when `shader_binding.programs()` has only one of the two pointers set. The
  scan therefore registers the blobs under a pair with one zero field, while a
  later draw supplies the fully-populated pair; `translatedGraphicsFor` will then
  return null and the draw falls back to the fixed-color probe shader. That is
  the plan's intended safe "mismatch → absence, never a wrong shader" outcome,
  but it means this change alone does not guarantee the real shader is selected
  in a live Terraria frame — the scan-time vs draw-time pair alignment needs a
  later task (or a real-HLE run) to confirm.
- `lastDiagnostic()` remains a single global shared across all pairs; a failure
  on one pair can be masked by a later single-stage registration on another
  pair. With the realistic one-pair runtime flow this is harmless, and per-pair
  diagnostics were out of scope.
- Bounded registry of 8 uses simple round-robin eviction; with more than 8
  distinct bound pairs the oldest translation is dropped and will be rebuilt on
  the next two-stage registration. Terraria's shader-set count was not measured.
- No dependency added; no PS5-path, shared-HLE, or `src/gpu/**` change.
