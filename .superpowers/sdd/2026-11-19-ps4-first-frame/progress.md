# SDD ledger — plan: docs/superpowers/plans/2026-11-19-ps4-first-frame.md

BASE: 137128f265885bb4d9ade013b7463a0bcd0a30b8

## Pre-flight conflict scan

| Pair / task | Produces vs consumes | Found |
|---|---|---|
| Task 1 → Tasks 4,5 | MISS inventory file consumed by both import-closure tasks | consistent |
| Task 2 → Task 6 | game_hook wired into game_run, needed before any frame run | consistent |
| Task 3 → Tasks 4,5 | `ps4_mode.hits.record(name: []const u8)` consumed by new PS4 wrappers | consistent |
| Tasks 4,5 | both edit PS4 registration files | overlap — execute sequentially, not in parallel |
| Task 6 → all | iterates only after wiring/counters/closures exist | consistent |
| Task 2 self | test in game_hook + game_run wiring; full suite verification | consistent |
| Task 3 self | hits.zig test + root.zig export; no shared trace change | consistent |

Ruling: Tasks 4 and 5 share the PS4 registration tables, so they run sequentially rather than in parallel — cost: one extra round-trip, avoids merge conflicts in a hand-edited NID table.
Task 1: complete (no commits, read-only; inventory at .superpowers/sdd/2026-11-19-ps4-first-frame/miss-inventory.md)
Task 1: Ruling: use the game-run enumerated unresolved NIDs as the implementation queue (37 for Terraria, 1 for OneShot) and the larger module-info MISS lists only as a fallback queue when link output is exhausted. Registering all 126/429 MISS NIDs would violate "implement console-specific things only if needed". Cost: more run/fix iterations.
Task 1: note: module-info was run with the prebuilt ./zig-out/bin/module-info because system Zig 0.17.1 cannot parse build.zig; counts differ from game-run because module-info omits provider PRXs. One Terraria NID (d88anrgNoKY) was reconstructed from an interleaved terminal artifact and is flagged in the inventory.
Task 2: complete (commits 137128f..eaae3a3, review clean)
Task 2: minor (deferred): game_hook module doc example calls configFromEnv() without seeding; bare call returns auto/false.
Task 2: minor (deferred): PS5_GNM_DIAG now enables for any non-empty value, not just "1"/"on".
Task 2: minor (deferred): lowered default-state preamble is filled but not yet consumed by an executor (Task 6 scope).
Task 2: Ruling: dormant runtime.zig::configFromEnv uses removed std.posix.getenv but is now caller-free and outside the two-file allowlist; leave it until a caller needs it — cost: future callers must use seedEnvConfig or fix runtime.zig.
Task 3: complete (commits eaae3a3..d838101, review clean)
Task 3: minor (deferred): extra setEnabled API, borrowed name slices, gate cached on first use — all acceptable for a single-threaded PS4-only diagnostic.
Task 4: complete (commits d838101..43af013, 1 Important fixed in round 1 via report-only reclassification, re-review clean)
Task 4: minor (deferred): all 37 stubs return SCE_OK; value-returning imports consumed on the first frame may need real values (Task 6).
Task 4: Ruling: build.zig/game_run.zig edits are PS4-only import edges required so hle wrappers and ps4_mode.hits share one module instance; behaviour-neutral for PS5, so the broader file scope stands.
Goal override: make Terraria render its first frame. Ruling: pursue Terraria in a separate worktree while Task 5 (OneShot imports) runs in the main worktree — disjoint checkouts, later merge. Evidence: game-run with PS5_PS4_MODE=on PS5_GNM_DIAG=1 PS5_CAPTURE_FIRST_FRAME=1 exits 134 with "thread panic: incorrect alignment" at src/hle/libs/ps4_heap.zig:98 insertFreeLocked via mallocImpl; no out/first-frame.ppm.
Task 5: complete (commits 43af013..95c20f6, review clean)
Task 5: minor (deferred): loader gap pages staged writable for all modules (final protections unchanged); hits capacity 128 < 148 combined NIDs; data-returning stubs need shared wrappers if exercised; CompanionUtil already covered by Task 4.
Real-rendering push: gcn-test merged/pushed (3309ec5) — hermetic 790-dword Terraria DCB test, 33/33 ps4mode tests, full build exit 0; fallback assertion is GREEN with shortcut marker until a translator exists.
gcn-integration: shared Vulkan receiver needs only SPIR-V words + bindings/scalars; no native pipeline rewrite. Blockers ranked: USER_DATA/T#/S# > vertex attrs > images/samplers > constants.
gcn-translator feasibility: rdna2/spirv writer reusable verbatim; need correct GCN decoder (~500-750 LOC) + PS4 options (~150-350 LOC). gcn_lower.classify is wrong for real GCN and must be replaced.
Active: gcn-abi (locate real shader blob), gcn-shader (decoder+translator+synthetic-shader test), gcn-resources (USER_DATA/T#/S# capture from real DCB).
gcn-resources merged/pushed (bf5f030): data-only PS4 module captures 13 SET_SH_REG USER_DATA bindings from Terraria's real DCB — PS T# colour target 0x10_168c8000 (1920x1080), a second T# 684x480, sampler, VS V#/raw pointers. test-ps4mode + full build green. Backend glue point identified: backend.zig:25751 drawPs4FixedColor calls drawGraphicsShadersWithModules (backend.zig:20618); replace probe words with gcn_translate.translatedGraphics() words once that lands.
Real shaders: gcn-abi FOUND real OrbShdr blobs in eboot (0x50a820..0x50bdc0) and ps4heap (0x20d806560+); shader-set args are zeroed descriptors, not shader code. dumped VS gcn-blob--4.bin (22 ISA dwords) and PS gcn-blob--3.bin (16 ISA dwords). gcn_blob reader merged.
gcn-shader merged (9f407ae): GCN decoder + SPIR-V translator reusing rdna2 writer, 41/41 ps4mode tests, 2085/2116 full suite.
Backend seam merged/pushed (04e28d9): vulkan imports ps4_mode; drawPs4FixedColor now uses translatedGraphics() words when present, probe otherwise.
Active: gcn-real-blob agent feeds real dumped blobs into translator, fixes decoder opcodes, registers shaders, and checks window histogram for real artwork.
gcn-real-blob merged (66895ba): real Terraria blobs decode+translate (49/49 ps4mode, 2093/2124 full), stage inferred from EXP target (blob--3=VS, blob--4=PS). Live: vs_words=169 ps_words=439, probe gone (0 FF4019), but frame ~1,913/2,073,600 pixels -> near black. Blocker: backend drawPs4FixedColor passes empty scalars/resources arrays; gcn_resources captures T#/S#/V# but they are not bound into the Vulkan descriptor set. Native path uses prepareGraphicsResources(backend.zig:26680, :28759)+updateSampledImageDescriptors(:29592).
