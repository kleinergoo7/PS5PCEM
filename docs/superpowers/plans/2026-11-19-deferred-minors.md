# Deferred minors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every deferred minor from the two completed rounds, using one small subagent per file domain.

**Architecture:** Five file-disjoint fixes run in parallel in separate git worktrees, then the coordinator merges, runs the full suite, re-extracts both ROMs, and reviews the branch. Historical task briefs are scratch artifacts in a deleted workspace, so there is nothing to change for that item.

**Tech Stack:** Zig 0.16.0, bash, git worktrees.

**Spec:** prior rounds' final review reports (recorded in conversation); this plan is the authority for the split.

## Global Constraints

- Zig 0.16.0, build with `/home/reng/tools/zig-x86_64-linux-0.16.0/zig`.
- Hard Zig cache cap is now **5 GB (5,000,000 KB)**.
- Each subagent touches only its listed files and works in its own worktree.
- Do not change extraction behaviour beyond the listed fixes.

## Tasks (one subagent each)

1. **npbind in-suite regression** — files `vendor/pkg2zar/core/src/test_pkg.zig`, `vendor/pkg2zar/core/src/source.zig`. Add a synthetic NP entry with a full aligned padding tail and assert the embedded SHA-1 in a test, so a future zero-padding regression fails CI. Verify `zig build test-p2z`.
2. **Plan documentation** — file `docs/superpowers/plans/2026-11-19-loose-ends.md`. Rewrite Review Focus items 2 and 3 to describe the actual retargeted fixes (VirtualQuery stale test; live DS4 axis / scripted input). Verify by reading the file.
3. **Build wrapper portability** — file `scripts/build-capped.sh`. Use `${ZIG:-/home/reng/tools/zig-x86_64-linux-0.16.0/zig}` with version check, use `"$local_cache"` on the build line, keep the 5 GB cap. Verify `scripts/build-capped.sh test-ps4`.
4. **pkgextractor file handles + header buffer** — file `src/pkgextractor.zig`. Close the header file handle before dispatching to `ps4pkg.extract` (avoiding three simultaneous opens), and zero-initialize the `[0x440]` header buffer / use the bytes-read count so short files cannot read undefined bytes. Verify `zig build test-ps4` and one ROM extraction.
5. **ps4.zig error buffer** — file `src/pkg/ps4.zig`. Replace fixed 512-byte `describe` buffers with a dynamic allocation so long paths cannot truncate failure reasons. Verify `zig build test-ps4`.

6. **Integration (coordinator):** merge all five, run `zig build test`, re-extract both ROMs, verify npbind SHA-1 tails, check cache < 5 GB, one whole-branch review.
