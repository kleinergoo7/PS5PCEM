# SDD ledger — plan: docs/superpowers/plans/2026-11-19-terraria-correct-first-frame.md

BASE: 2d7567798bb181ebb6d3220f25bc9944efbf2251
Spec: docs/superpowers/specs/2026-11-19-terraria-correct-first-frame-design.md (approved)
Models: implementers/reviewers opencode-go/hy4-flash-free (paid tiers returned "Insufficient balance" before Task 1 started); final review opencode-go/hy4-flash-free (user directive: use Hy4 flash Free for all subagents). Ruling: use free tiers — the paid-model dispatch failed with no work done, so no quality tradeoff was available. Cost: less model capacity for review; mitigated by task-scoped briefs and diff packages.

## Pre-flight conflict scan

| Pair / task | Produces vs consumes | Found / ruling |
|---|---|---|
| Task 1 → Tasks 2-6 | `ProgramPair`, `Capture`, `nextDrawResources`, per-draw `Resources` consumed by every later task | Consistent. |
| Task 1 ↔ Task 2 | Both edit `backend.zig`; Task 1 also `root.zig` | Sequential execution (not parallel) — overlap on the same PS4 draw seam. |
| Task 2 → Tasks 3-6 | `registerShaderFor`, `translatedGraphicsFor`, `scalarSlotsFor`, program-keyed registry | Consistent. |
| Task 3 → Task 6 | `fragmentInputsFor` consumed by the final gate | Consistent. |
| Task 4 → Task 6 | `vertexDataSourceFor` + removal of synthetic corners consumed by final gate | Consistent. Ruling: the `vertex_position_corner_override` writer option and its rdna2 unit test stay (default-off, native byte-identical); only PS4 stops using it. Cost: one unused default-off option remains. |
| Task 5 → Task 6 | `sampledImageUserIndexFor` consumed by final gate | Consistent. Ruling: any test calling `nextDrawResources()` must call `resetCapture()` first — the FIFO is global state; cost: tests must remember the reset. |
| Task 5 ↔ Task 1 | Task 1 snapshots USER_DATA per draw; Task 5 selects the USER_DATA slot by decoded resource SGPR | Consistent: Task 1's `psImage()` helper is for single-T# fixtures only; Task 5 owns correct slot selection. |
| Task 1 self | Files list includes `root.zig`; step 3 exports `ProgramPair`; commit includes it | Agrees. |
| Task 2 self | Consumes `ProgramPair` from Task 1; commit list excludes `root.zig` (does not touch it) | Agrees. |
| Task 4 self | Declares `vertexDataSourceFor(res)` returning null with diagnostic when no V# exists, matching the anti-goal "never fabricate" | Agrees. |
| Task 6 self | Gate test expects two different T#s from `capture(&real_terraria_dcb)`; Task 1 fixtures have one T# each, Task 5 owns slot selection | Agrees; gate uses the real fixture's two draws. |

Scan clean after rulings. Execute tasks sequentially; no fix instruction in the plan was found to contradict the spec's anti-fabrication rule.
Task 1: complete (commits 2d75677..32ce911, review clean)
Task 1: minor (deferred): nextDrawResources() is consumed at drawPs4FixedColor entry before target/shader validation; an early bail shifts the FIFO. Brief explicitly requires entry consumption; report's ring-full concern was proven unreachable by reviewer.
Task 2: complete (commits 32ce911..4034ccf, review clean)
Task 2: CARRY-OVER to Task 6: tryRegisterRealShaders is once-only and fires on the first shader-set import with a partial bound pair; draw-time query uses the full pair -> fallback to probe. Task 6 must make live draws use the real translated shader (defer scan until both pointers set or register against the actual draw-time pair). Reviewer: task-scoped approved, real risk to live gate.
Task 2: minor (deferred): global lastDiagnostic across pairs; pre-existing FIFO-at-entry concern unchanged.
Task 3: review ⚠️ (Needs fixes) — 2 Important: no real interpolated UV (real blobs have no VINTRP; coordinates still host-updated scalars), vacuous negative-only test. Ruling: spec requires real UVs, so no re-scope; fix round 1 dispatched to implement positive interpolated-coordinate path from VS PARAM-derived fragment inputs.
Task 3: minor (deferred): mismatch publishes zero-input shader instead of invalidating pair; two tests register same blobs in opposite stages; standalone translateShader keeps hardcoded 0b11 mask; EXP shift lacks >32 guard.
Task 3: complete (commits 4034ccf..a758925, 1 fix round: 2 Important addressed, re-review clean)
Task 3: residual (deferred): UV interpolation comes from VS PARAM0 -> Location-0 Vulkan Input, not recovered GCN VINTRP (real blobs have none); only lowest PARAM bit and 2D samples covered; coordinate normalization bypassed, so UV values are guest-sourced but not proven normalized.
Task 4: review ❌ (Needs fixes), 2 Critical + 2 Important: real VS has no position source (specific VOP2/VOP1 ops lowered to s_nop at gcn_decode.zig:343-355), staged V# buffer unused, hardcoded stride 16, use_vertex_index=false for all stages.
Task 4: Ruling: plan already instructs fixing gcn_decode opcode handling when real blobs need it, so expand fix scope beyond the brief's three files to PS4-only `src/ps4_mode/gcn_decode.zig` as needed. Spec forbids synthetic corners; reverting the override removal is not acceptable. Cost: wider diff and review.
Task 4: fix round 1/5 (4 addressed, 1 new Important — unconditional Terraria MUBUF injection into every PS4 VS; commits a758925..699377f)
Task 4: Ruling on re-review caveat: host-authored MUBUF that reads real staged V# bytes is accepted as guest-sourced data for first-frame bring-up; spec forbids fabricated pixels/positions, not a reconstructed fetch into real guest bytes. Residual risk: guest VS vector math remains unrecovered; final review must see it. Cost: first-frame positions are plausible but not proven faithful to guest math.
Task 4: complete (commits a758925..6d8201e, 2 fix rounds: 2 Critical + 2 Important + 1 new Important all addressed, re-review clean)
Task 4: residual (deferred): live registration still uses registerShaderFor with null vertex source, so measured stride reaches tests only (Terraria stride is 16 so behavior matches); injected MUBUF is gated to exact 7-word Terraria VS prolog; guest VS vector math remains unrecovered.
Task 5: review ⚠️ (task Approved) with 1 Important: sampledImageUserIndexFor returns raw decoded SGPR (tsgpr) as USER_DATA index without subtracting PS base 0x0c; works for Terraria by numerical coincidence. Ruling: plan explicitly requires "SGPR number minus stage USER_DATA base", so dispatch fix round 1 rather than park.
Task 5: minor (deferred): first-image-only assumption documented only in report; vs_words registered as .pixel in one test is confusing but valid.
Task 5: complete (commits 663a2db..2d276c5, 1 fix round: 1 Important addressed, re-review clean)
Task 5: residual (deferred): normalization heuristic overlaps 12..15 for row-relative vs absolute SGPR; single-image PS only.
Task 6: BLOCKED on live gate (commit d54587b). Controller independently confirmed: PPM 1920x1080 has only 3 non-black rows (595-597), 1507 texels; 3 runs byte-identical. Real shader active (vs=524/ps=698 words), texture staged; geometry collapses to a horizontal line.
Task 6: Ruling on blocker: plan's assumption that a reconstructed MUBUF plus Location-0 UV would yield correct geometry is wrong. Per handling-reports #4, rule a narrower diagnostic-first repair: decode the real VS's actual SOPK/SMRD/VOP2/EXP semantics from the 16 embedded ISA words and recover positions from guest constant/vertex data; no synthetic corners, no relaxing the gate. Re-dispatch with changed scope (PS4-only decoder/translator/backend allowed), Hy4 flash Free per user directive. Cost: additional deep decoder work; benefit: honesty about feasibility and a real chance at the gate.
Task 6: re-dispatch result — real VS ISA fully decoded (fd6fc39): POS0 from VertexIndex via v_and/v_lshlrev/v_add/v_cvt, injected MUBUF removed, fullscreen quad geometry now correct. Still BLOCKED: PS SMRD constant loads have no source — pixel USER_DATA[2:3] are 0/0 in captured DCB; readback colored_pixels=0; frame remains thin band / black. Geom gate still unmet (only 357 px >=100).
Task 6: Ruling: blocker is missing guest data, not a logic defect. Per handling-reports #1 re-dispatch same agent with added context: search all captured DCBs and guest memory for the PS constant buffer / USER_DATA words referenced by the PS (blob--4 ISA with SMRD loads), stage them through the existing PS4 dynamic scalar mechanism; if genuinely absent, final BLOCKED with exact addresses/scan evidence. No fabricated UVs/constants, gate unchanged.
Task 6: 3rd re-dispatch result (8649134): PS constants DO exist in guest stream (1,706/3,088 DCBs carry nonzero pxUD[2:3]); the first draw's own DCB binds 0/0 and the bytes are still zero at that instant — guest writes them later. Real bug found+fixed: ring-full dropped oldest capture and reset the draw cursor, so draws replayed the first setup snapshot forever (Task 1 reviewer had ruled ring-full mis-association unreachable — that ruling was wrong; 0/2000 -> 329/2000 draws saw a pointer after fix).
Task 6: controller measurement of const-run-1.log: flips #1..#16 ALL present mean rgb=0,0,0 with max 1,937 coloured px (of 2,073,600); 1 fullscreen compute dispatch skipped every frame (`MissingComputeProgram groups=32640x1x1`, 32640*64 = 1920*1088). `levels=0..0 want_levels=1` is base_level=0/last_level=0 = one mip, not a bug.
Task 6: Ruling: the gate targets a frame the guest itself presents empty. Before any further shader-constant work, measure a LATER flip (dump flip N) to tell "guest still loading" from "guest stuck in a black render loop". No gate relaxation, no fabricated constants.
