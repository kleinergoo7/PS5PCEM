# PS4 PKG extraction in `pkgextractor` — design

Date: 2026-11-18

## Intent

Make `pkgextractor` extract PS4 fake-signed packages (`.pkg`, magic `\x7FCNT`) into a
directory with a runnable `eboot.bin`, alongside its existing PS5 FPKG/ZAR support.
User goal: a full runnable extracted ROM from
`[SPSX]-OneShot.World.Machine.Edition-CUSA34845-USA-GAME-v1.00-9.50+.pkg`, not just
the `sce_sys/` metadata the current code already writes.

## Why this approach

The extraction logic already exists, in Zig, in <https://github.com/kleinergoo7/pkg2zar>
(pinned commit `26abc7504b401e7aaff4caf222d0e85ce999ba4d`, GPL-3.0). It was verified
here end-to-end on the sample PKG:

- `plan`/`extract`: 4,485 files, 1,465,897,453 bytes.
- Byte-for-byte diff against the reference extractor (shadPS4Plus AppImage,
  SHA-256-verified): 4,484/4,485 files identical; sole difference is the final 4
  bytes of `sce_sys/npbind.dat` (same size, valid header) — a decryption tail
  discrepancy in one of the two tools, not game data.

Reimplementing key derivation + AES-XTS + PFSC + zlib in PS5PCEM would be larger and
unverified.

## Goals / non-goals

- Goal: detect PS4 PKG, decrypt and unpack the full PFS tree into the requested
  output directory, keeping the existing PS5/ZAR paths unchanged.
- Non-goal: retail PSN packages (Sony private keys are not public — shadPS4 refuses
  these too), delta updates, PS4 game execution itself, and fixing the 4-byte
  `npbind.dat` difference.
- Constraint: PS5PCEM **stays on Zig 0.16**. PS4 decryption needs no user keys and
  no firmware — all keysets are embedded in `pkg2zar`'s `core/src/keys.zig`.
- Constraint: ps5pcem build cache stays under 1 GB.

## Approaches considered

1. **Pinned Zig package dependency on `pkg2zar`** — rejected. Zig 0.16 evaluates
   the dependency's `build.zig`, which uses 0.17 APIs (`addPassthruArgs`,
   `Optimize.debug`) and pulls dvui/zstd/translate_c that also need 0.17.
2. **Vendor `pkg2zar/core/src/` and build it locally with 0.16** — chosen. Verified:
   the whole core compiles cleanly with the repo's Zig 0.16.0 when its `build.zig`
   is not evaluated.
3. Shell out to the C++ shadPS4Plus AppImage — rejected: external binary dependency,
   C++ source tree, no benefit over #2.
4. Port the crypto/PFS code into `src/pkg/` from scratch — rejected: larger and
   unvalidated versus the verified tool.

## Design (approach 2)

- Add `vendor/pkg2zar/` containing the pinned `core/src/*.zig`, upstream `LICENSE`
  and `NOTICE`, with the commit hash in a comment so updates are traceable.
- Add a 0.16-compatible module for that core in `build.zig` and import it into
  `pkgextractor` (no new external dependency; zstd externs stay unlinked because
  the extraction path never writes ZAR).
- In `pkgextractor.zig`, keep current dispatch, but when magic is `\x7FCNT` and the
  header is a PS4 PKG — `package_size` at `0x430` equals the file size and
  `pfs_image_offset` at `0x410` is in range (PS5 CNT has neither) — call
  `pkg2zar`'s `extract.run` to write the tree into `dest_path`. Other CNT files
  keep the existing `visitExtractable` path.
- Update `pkgextractor` usage text and `docs/getting-started.md` to mention PS4 PKG.

## Verification

- `zig build -Doptimize=ReleaseFast` with Zig 0.16.0 and the existing cache setup.
- Run the new path on the sample PKG into a fresh directory; compare file count,
  total bytes, and SHA-256 manifest against `/tmp/opencode/reference-manifest.txt`
  (4,485 files / 1,465,897,453 bytes). Expect only `sce_sys/npbind.dat` to differ.
- Confirm `cache` total remains under 1 GB.
