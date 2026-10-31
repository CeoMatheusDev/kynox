# Building and testing Kynox

> Reproducible build/validation instructions. Every command in this file was
> checked against `build.zig` on 2026-10-31; the results of the last executed run
> are recorded at the end. Do not claim a target passed unless you ran it.

## 1. Toolchain

| Requirement | Value | Source of truth |
|---|---|---|
| Zig | **0.17.0** | `build.zig.zon` → `minimum_zig_version = "0.17.0"` |
| Target (produced artifacts) | `x86_64-uefi-none` (loader), `x86_64-freestanding-none` (kernel and apps) | `build.zig` |
| Build system | Zig's own build graph (`build.zig`), no external build tool | `build.zig` |
| External dependencies | **none** | `build.zig.zon` → `.dependencies = .{}` |
| C compiler / libc | not required | — |
| Host OS | Linux or macOS x86_64 (build host) | — |

Zig 0.17.0 is **not** published on the GitHub releases page (which carried
0.15.x when this was written). Obtain 0.17.0 from a channel that publishes it.
The audit verified the build with the `ziglang` 0.17.0 distribution:

```sh
python3 -m pip install --target /tmp/zigenv ziglang==0.17.0
export PATH=/tmp/zigenv/ziglang:$PATH
zig version        # 0.17.0
```

Any equivalent official 0.17.0 distribution is acceptable, but record which one
you used when reporting a validation result.

## 2. Build

```sh
zig build
```

Produces:

| Artifact | Description |
|---|---|
| `zig-out/bin/kynox-boot.efi` | UEFI boot application (KNB) |
| `zig-out/bin/kynox-kernel` | freestanding kernel ELF (KNK) |
| `zig-out/bin/kynox-fsimg` | image generator (host tool) |
| `zig-out/bin/kynox.img` | bootable FAT16 EFI system partition containing `\EFI\BOOT\BOOTX64.EFI` and `\boot\kynoxk.elf` |

The image generator runs as part of the default install step, so `zig build`
alone produces the image. `zig-out/` and `.zig-cache/` are ignored by Git.

Useful variants:

```sh
zig build -Doptimize=ReleaseSmall     # smaller kernel (debug default)
zig build image                       # only the image step
```

## 3. Host tests

```sh
zig build test
```

Runs 19 test artifacts on the host (pure logic only: contracts, paging math,
allocators over supplied memory, filesystems, codecs, KVDI with injected MMIO,
IPC, capabilities, raster/compositor). Last recorded run: **615/615 tests
passed** (2026-10-31, Zig 0.17.0).

## 4. QEMU integration (requires QEMU + OVMF)

Prerequisites:

| Package | Files used | Notes |
|---|---|---|
| QEMU | `qemu-system-x86_64`, `qemu-img` | TCG is enough; KVM optional |
| OVMF | `OVMF_CODE.fd` + `OVMF_VARS.fd` (or the `_4M` variants) | searched in `/usr/share/edk2*`, `/usr/share/OVMF`, `/usr/share/qemu`, `/usr/lib`, `/usr/local/share`, `/opt`. Override with `OVMF_CODE=... OVMF_VARS=...` |

Targets:

```sh
zig build qemu-test              # automated boot: asserts ~45 serial markers
zig build qemu-storage-test      # VirtIO Block I/O + persistence across two boots
zig build qemu-interactive-test  # PS/2 + graphics input checks
zig build check                  # unit + boot + storage (NOT the interactive one)
zig build qemu                   # interactive boot for manual inspection
```

The scripts fail with an explicit diagnostic when QEMU or OVMF is missing; a
missing prerequisite is a *skipped* validation, never a pass.

## 5. How to record a validation result

Add a row to the verification record in `README.md` and to the release notes
draft (`docs/releases/0.1.0-alpha.1.md`) with:

- exact command;
- date;
- Zig version and distribution;
- QEMU/OVMF versions (when applicable);
- result, including the failing marker names when a QEMU check fails.

Then update `docs/PROJECT_STATUS.json` (`executed_validations` and the affected
subsystems' `validation` objects) and `docs/PROJECT_STATUS.md` in the same
change.

## 6. Last executed run (2026-10-31)

| Command | Result |
|---|---|
| `zig version` | `0.17.0` |
| `zig build` | success — 13/13 steps |
| `zig build test` | success — 39/39 steps, 615/615 tests |
| `zig build qemu-test` | not executed — QEMU/OVMF unavailable |
| `zig build qemu-storage-test` | not executed — same |
| `zig build qemu-interactive-test` | not executed — same |

## 7. Troubleshooting

| Symptom | Cause / action |
|---|---|
| `zig: command not found` | toolchain not installed; see §1 |
| build error about `minimum_zig_version` | wrong Zig version; the tree requires 0.17.0 exactly (no compatibility shims) |
| `no OVMF firmware found` | install OVMF or set `OVMF_CODE`/`OVMF_VARS` (§4) |
| QEMU test hangs until timeout | capture the serial log written by the script; the failing marker list is printed at the end |
| `kynox.img` unexpectedly large | the kernel is built in debug; use `-Doptimize=ReleaseSmall` |
