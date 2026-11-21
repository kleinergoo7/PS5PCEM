# Task 5: Close OneShot's PS4 imports — report

## Status

Done. OneShot (`/tmp/opencode/verify-a`) links with **zero `unresolved` lines and
zero `cannot link` lines**. 111 PS4 NIDs are registered in the PS4-only file
`src/hle/libs/ps4_oneshot_stubs.zig`, wired through `src/hle/root.zig` exactly as
Task 4 did for Terraria. No PS5 export was modified; every registration uses
`id_override`.

## Method — game-run driven, not module-info driven

Per the controller ruling, I never bulk-registered the 429 module-info MISS
entries. I iterated on the authoritative link queue:

1. Baseline: 1 unresolved — `hHrGoGoNf+s libSceSysmodule func` (in
   `sce_module/libSceFios2.prx`), plus `cannot link … RelocationTargetUnavailable`.
2. Registered that one NID; rebuilt; re-ran link.
3. Each subsequent cycle surfaced the next failing module's full unresolved set:
   - `x64/fmod/libfmod.prx`: 57 + 1 (re-run exposed one more,
     `0BzLGljcwBo`) — 9 `libSceAudio3d`, 49 `libSceGnmDriver`.
   - `scePlayStation4.prx`: 52 — 24 `libSceCamera`, 10 `libSceGnmDriver`, and
     18 service-library NIDs.
4. Final run: zero unresolved, zero cannot link; the emulator proceeds into
   guest execution (`[ps4heap] malloc` traces).

Note: the module-info MISS inventory did **not** cover `x64/fmod/libfmod.prx` or
`scePlayStation4.prx`, so a module-info-driven approach would have missed 110 of
the 111 NIDs. A few `unresolved` lines were byte-interleaved with buffered stdout
(`[link] N imports … <<APPLY>>`) or wrapped; I recovered those NIDs from the raw
stderr (and cross-checked `scePlayStation4.prx` against its module-info MISS set)
so none were silently dropped.

## Supporting change required to reach link completion

The first `cannot link … RelocationTargetUnavailable` was **not** an import
problem. Instrumenting `src/loader/linker.zig` (temporarily; reverted) showed a
`R_X86_64_RELATIVE` write at guest offset `0x60000` failing with
`ProtectionDenied`. OneShot's `libSceFios2.prx` keeps its GOT/jump-slot table in
the page gap between its two PT_LOAD segments (`0x0..0x5c508` r-x and
`0x64000..0x12852c` rw-). `prepare()` mapped only the segment pages, leaving the
gap unmapped, so relocation writes into it failed before any later module could
be linked.

Fix in `src/loader/image_loader.zig`: stage the whole image span (min to max
segment page boundary) writable, then apply final protections only to the real
segment pages in `link()`. Modules without a gap are unaffected; gap pages stay
writable (they are data slots). Added regression test
`"the page gap between load segments is staged writable"`. This is a loader
correctness fix, not a HLE change — no shared HLE implementation was touched.

## Classification table

All 111 NIDs are **value-returning status / idempotent** calls with **no HLE
export under their PS4 NID**. By the brief's rules they land on minimal PS4 logic
returning `SCE_OK` (`errno.ok`, 0) — the deliberate plausible success value for
these paths, not a blind zero for a value-returning import. `SCE_OK` is what the
Terraria PS4 stubs (43af013) already use for the same classes. Every stub records
its own NID via `ps4_mode.hits.record` (gated by `PS5_GNM_DIAG`).

| Library | Count | Classification | Rationale / implementation | NIDs |
|---|---:|---|---|---|
| `libSceSysmodule` | 1 | value-returning status **with a shared counterpart** | `hHrGoGoNf+s` is the PS4 alias of the shared `sceSysmoduleLoadModule` (registered under PS5 NID `g8cM39EUZ6o` in `sysmodule.zig`, which returns `errno.ok`). PS4-only thunk returns the same `SCE_OK` — wrapper-equivalent, no shared file edited. | `hHrGoGoNf+s` |
| `libSceAudio3d` | 9 | value-returning status / idempotent; no shared counterpart | libfmod audio-engine calls (init, listener/source state, submit/render class). No Audio3d HLE export exists under these PS4 NIDs → minimal PS4 logic returning `SCE_OK`. | `1HXxo-+1qCw`, `9tEwE0GV0qo`, `HbxYY27lK6E`, `VEVhZ9qd4ZY`, `YaaDbDwKpFM`, `Yq9bfUQ0uJg`, `lw0qrdSjZt8`, `pZlOm1aF3aA`, `ucEsi62soTo` |
| `libSceGnmDriver` | 59 | value-returning status / idempotent driver commands; no shared counterpart under these PS4 NIDs | Same class as the 26 GnmDriver NIDs stubbed for Terraria. The shared GNM/AGC registry uses different PS5 NIDs, so these are PS4-only → minimal PS4 logic returning `SCE_OK`. | `+AFvOEXrKJk`, `0BzLGljcwBo`, `4v+otIIdjqg`, `5SHGNwLXBV4`, `5uFKckiJYRM`, `5udAm+6boVg`, `6YRHhh5mHCs`, `A+uGq+3KFtQ`, `BgM3t3LvcNk`, `ED9-Fjr8Ta4`, `EJapNl2+pgU`, `FFVZcCu3zWU`, `Fa3x75OOLRA`, `Fwvh++m9IQI`, `GGsn7jMTxw4`, `GNlx+y7xPdE`, `Ga6r7H6Y0RI`, `HlTPoZ-oY7Y`, `HzMN7ANqYEc`, `Kl0Z3LH07QI`, `KnldROUkWJY`, `Kx-h-nWQJ8A`, `MBMa6EFu4Ko`, `MYRtYhojKdA`, `NfvOrNzy6sk`, `Q7t4VEYLafI`, `R6z1xM3pW-w`, `RX7XCNSaL6I`, `SXw4dZEkgpA`, `UtObDRQiGbs`, `V31V01UiScY`, `X9Omw9dwv5M`, `XiyzNZ9J4nQ`, `Z43vKp5k7r0`, `byXlqupd8cE`, `cFCp0NX8wf0`, `cUCo8OvArrw`, `dewXw5roLs0`, `ffrNQOshows`, `fzJdEihTFV4`, `hsZPf1lON7E`, `iFirFzgYsvw`, `ihxrbsoSKWc`, `im2ZuItabu4`, `jHdPvIzlpKc`, `jRcI8VcgTz4`, `k7iGTvDQPLQ`, `mLVL7N7BVBg`, `nEyFbYUloIM`, `nLM2i2+65hA`, `oL4hGI1PMpw`, `oYM+YzfCm2Y`, `qGP74T5OWJc`, `rTIV11nMQuM`, `stDSYW2SBVM`, `tZCSL5ulnB4`, `thbPcG7E7qk`, `wED4ZXCFJT0`, `yb2cRhagD1I` |
| `libSceCamera` | 24 | value-returning status / idempotent; no shared counterpart | Camera service calls (open/close/start/read class). No HLE export under these PS4 NIDs → minimal PS4 logic returning `SCE_OK`. Camera is not exercised before first frame. | `2G2C0nmd++M`, `3i5MEzrC1pg`, `9EpRYMy7rHU`, `BHn83xrF92E`, `HX5524E5tMY`, `K7W7H4ZRwbc`, `OMS9LlcrvBo`, `ObIste7hqdk`, `P-7MVfzvpsM`, `QI8GVJUy2ZY`, `RTDOsWWqdME`, `VQ+5kAqsE2Q`, `WVox2rwGuSc`, `XqYRHc4aw3w`, `a5xFueMZIMs`, `bSKEi2PzzXI`, `c6Fp9M1EXXc`, `jMv40y2A23g`, `k3zPIcgFNv0`, `lhEIsHzB8r4`, `p6n3Npi3YY4`, `tslCukqFE+E`, `wgBMXJJA6K4`, `zrIUDKZx0iE` |
| `libSceVideoRecording` | 6 | value-returning status / idempotent; no shared counterpart | Recording service calls; minimal PS4 logic returning `SCE_OK`. | `KHvkPQJDMLk`, `OOFxrMY+mfI`, `bGYkY6q3bIw`, `fZJQzFK4Gv4`, `s28dalBwp2g`, `tWoe9IlGAhs` |
| `libSceSaveData` | 4 | value-returning status; no shared counterpart under these PS4 NIDs | Save-data service calls; `SCE_OK` is the plausible success value. No real I/O is required for link/first-frame. | `0z45PIH+SNI`, `RQOqDbk3bSU`, `VwadwBBBJ80`, `lU9YRFsgwSU` |
| `libSceScreenShot` | 2 | value-returning status / idempotent | Screenshot service calls; minimal PS4 logic returning `SCE_OK`. | `G7KlmIYFIZc`, `ahHhOf+QNkQ` |
| `libSceRemoteplay` | 2 | value-returning status / idempotent | Remoteplay service calls; minimal PS4 logic returning `SCE_OK`. | `mrNh78tBpmg`, `xQeIryTX7dY` |
| `libSceSystemService` | 2 | value-returning status / idempotent | System-service calls; minimal PS4 logic returning `SCE_OK`. | `4imyVMxX5-8`, `eLWnPuja+Y8` |
| `libScePlayGo` | 1 | value-returning status / idempotent | PlayGo call; minimal PS4 logic returning `SCE_OK`. | `LosLlHOpNqQ` |
| `libSceUserService` | 1 | value-returning status / idempotent | User-service call; minimal PS4 logic returning `SCE_OK`. | `lUoqwTQu4Go` |

**Total: 111 NIDs across 11 libraries.** Breakdown by surfacing module:
`sce_module/libSceFios2.prx` 1, `x64/fmod/libfmod.prx` 58,
`scePlayStation4.prx` 52.

The brief also calls out `libSceCompanionUtil`: no OneShot-specific CompanionUtil
NID ever surfaced in the link queue — the four CompanionUtil NIDs are already
registered by Task 4's `ps4_terraria_stubs.zig`, and OneShot's link is clean
without adding any here. The `libSceSysmodule` alias is the one NID the brief
named that did surface, and it is registered above.

## Verification

- **Build** (Zig 0.16.0, `ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-global-cache-0.16`):
  `zig build -p zig-out` → exit 0.
- **game-run**: `PS5_PS4_MODE=on ./zig-out/bin/game-run --app0 /tmp/opencode/verify-a /tmp/opencode/verify-a/eboot.bin`
  → link phase completes with **0 `unresolved` and 0 `cannot link`**; the guest
  then enters its main loop and runs (verified via `[ps4heap] malloc` traces).
  Because the title's main loop does not self-terminate, the command was stopped
  with SIGTERM after link closure was confirmed.
- **`zig build test`** (Zig 0.16): exit **0**, no `FAIL`/`error`/`panic` —
  including the new `"the page gap between load segments is staged writable"`
  regression test and the `"every OneShot NID resolves under its exact PS4
  identifier"` test. The log contains `failed command:` lines from other test
  binaries' diagnostic subprocesses, but the overall step succeeds.
- **Commit**: `95c20f6 feat(ps4): close OneShot import closure` (3 files:
  `src/hle/libs/ps4_oneshot_stubs.zig`, `src/hle/root.zig`,
  `src/loader/image_loader.zig`). The report itself lives in the gitignored
  `.superpowers/sdd/` directory and is not committed.

## Concerns / limits

- `ps4_mode.hits.capacity` is 128 distinct names. Terraria (37) + OneShot (111)
  = 148, so with `PS5_GNM_DIAG` enabled some later wrapper names are dropped
  from the diagnostic report. This affects diagnostics only, not resolution.
- The stubs return `SCE_OK` without producing data for camera / video-recording
  / save-data reads. Those subsystems are not exercised before first frame;
  real behavior would need shared-implementation wrappers once the title reaches
  them.
- The loader gap fix maps the inter-segment gap as writable for **all** modules,
  not just PS4 ones (the titles package PS4-era modules as `sce_dynamic`, so an
  `isPs4()` gate would not catch them). It is a strict superset of the previous
  staging map; final protections are unchanged for real segment pages.
- I stopped my own guest run after link closure; the command as written does not
  terminate on its own because the title loops indefinitely.
