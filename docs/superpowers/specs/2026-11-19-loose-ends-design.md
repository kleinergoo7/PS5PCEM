# Loose ends — design

Date: 2026-11-19

## Intent

Close the three items left after PS4 PKG extraction shipped: the 4-byte
`npbind.dat` tail discrepancy, two failing HLE tests, and the build-cache cap.
Work is to be executed by many small subagents, each with one simple task, not
by one broad agent.

## Goals / non-goals

- Goals: full `zig build test` green; `npbind.dat` output matches the authoritative
  decryptor on both sample ROMs; a repeatable build command that keeps the
  ps5pcem cache under 1 GB.
- Non-goals: playing the games in the emulator, retail PKG support, refactoring
  the vendored core beyond the one decryption fix, and changing PS4 extraction
  behaviour other than the `npbind.dat` bytes.
- Constraint: Zig 0.16.0; ps5pcem cache under 1 GB; no new runtime dependency.

## Approaches

- One agent for all three items — rejected: the three domains share no code,
  and a broad brief invites drift.
- Research-and-fix pairs per domain — chosen. Read-only agents first, then
  narrowly scoped fix agents in separate worktrees. Costs one extra round-trip
  per domain but keeps every individual task simple and reviewable.
- Skip investigation and patch symptoms — rejected: both HLE failures have
  concrete error codes (`0x8002000d`, port 129) whose root causes are unknown.

## Design

- **Domain A (`npbind.dat`):** read-only agent determines which decryptor is
  authoritative by reading `vendor/pkg2zar/core/src/source.zig:sceEntryData`,
  the shadPS4Plus `aesCbcCfb128DecryptEntry` code, and the two sample tails.
  If the vendored zero-padding is wrong, a fix agent patches only
  `vendor/pkg2zar/core/src/source.zig` and records the divergence in
  `vendor/pkg2zar/NOTICE`; the user chose patching the vendored core over a
  wrapper. A regression test pins the resulting `npbind.dat` bytes.
- **Domain B (`kernel_memory`):** read-only agent isolates why batch-map with
  `start=0, offset=0x10000` returns `0x8002000d` and unmap returns `0x80020016`.
  A fix agent changes only the root-cause code plus its test.
- **Domain C (`pad`):** read-only agent finds why the primary-user pad port is
  129 instead of 128. A fix agent changes only that code plus its test.
- **Domain D (cache):** one agent adds `scripts/build-capped.sh`, which builds
  with an explicit cache dir, reports size, and prunes it to stay under 1 GB;
  plus one doc line in `docs/getting-started.md`.
- **Integration:** all fix worktrees merge back before the final verification:
  `zig build test`, both ROM extractions, manifest comparison, whole-branch
  review. Fix agents must not touch each other's files.

## Execution shape

Stage 1: four agents in parallel (three read-only investigators + cache script).
Stage 2: up to three fix agents in parallel, each in its own worktree, brief
built from that domain's investigation. Stage 3: integration and review by the
coordinator.
