# QEMU validation procedure and recorded attempts

Status of this document: **procedure prepared, no run has succeeded.** This
environment has no emulator and no UEFI firmware. Nothing below is a result;
see §5 for what was actually attempted and how it failed.

## 1. Why it matters

`zig build test` compiles and runs host-side unit tests. It cannot prove that
the loader, the handoff, the kernel, the drivers or the graphics path work on a
machine. The only evidence for those is a boot in an emulator with real UEFI
firmware, and that evidence does not exist in this repository yet (audit
findings A-02 and A-14).

## 2. Prerequisites

| Component | Version used to write this document | Notes |
|---|---|---|
| Linux x86_64 | kernel 6.1 (`e2b.local`), Ubuntu userland, bash 5.2.15 | any recent distribution |
| Zig | 0.17.0 (`pip3 install --target /tmp/zigenv ziglang==0.17.0`) | matches `build.zig.zon` |
| QEMU | **not installed here** | package `qemu-system-x86` (Debian/Ubuntu) |
| OVMF firmware | **not installed here** | package `ovmf`; `OVMF_CODE.fd` + `OVMF_VARS.fd` |

The scripts accept the firmware through `OVMF_CODE` and `OVMF_VARS` (both must
be set together) or find it in `/usr/share/edk2/ovmf`, `/usr/share/edk2/x64`,
`/usr/share/edk2-ovmf`, `/usr/share/OVMF`, `/usr/share/qemu`, or by searching
`/usr/share`, `/usr/lib`, `/usr/local/share`, `/opt`.

The image is read-only and copied before the run; the firmware variables are
copied as well, so a run never modifies the build output.

## 3. Commands

```bash
zig build                      # produces zig-out/bin/kynox.img (128 MiB, FAT16)
zig build qemu-test            # boot chain + serial assertions
zig build qemu-storage-test    # two boots, VirtIO Block persistence
zig build qemu-interactive-test# persistent PS/2 input and graphics
```

Each step is `bash tests/integration/<script>`; they can be run directly with
`--image=`, `--timeout=` and, for the boot test, `--verify-kvdi-log=<path>`.

## 4. VM configuration actually used by the scripts

| Setting | Value |
|---|---|
| Machine | `q35` |
| Memory | 256 MiB |
| CPUs | 1 (`-smp 1`); the kernel's SMP path still runs on the BSP only |
| Boot medium | `zig-out/bin/kynox.img`, raw, `virtio-blk-pci,disable-legacy=on` |
| Firmware | two pflash drives: `OVMF_CODE` (read-only) and a private copy of `OVMF_VARS` |
| Console | `-serial file:<tmp>/serial.log` |
| Monitor | `unix:<tmp>/monitor.sock,server=on,wait=off` (screenshots via `screendump`) |
| Display | `-display none` |
| Other | `-no-reboot`; the emulator is stopped when the boot reaches its end marker or at `--timeout` |

`zig build qemu-storage-test` additionally creates a second disk image for the
persistence cycle and boots the same EFI image twice.

## 5. Recorded attempts

| Date | Command | Exit code | Result | Exact failure |
|---|---|---:|---|---|
| 2026-10-31 | `zig build qemu-test` | 2 | **not executed** | `qemu-boot-test: no OVMF firmware found`, then the seven candidate pairs and the four search roots; `boot-qemu.sh` exits 2 |
| 2026-10-31 | `zig build qemu-storage-test` | 2 | **not executed** | fails through the same `qemu-test` dependency, same message |
| 2026-10-31 | `zig build qemu-interactive-test` | 2 | **not executed** | same missing OVMF firmware |
| 2026-10-31 | `command -v qemu-system-x86_64` | 1 | **absent** | binary not installed |
| 2026-10-31 | `find / -name 'OVMF*.fd'` | 0 | **absent** | no firmware anywhere in the filesystem |

Environment facts recorded for reproducibility:

- `uname -a` → `Linux e2b.local 6.1.158+ #1 SMP PREEMPT_DYNAMIC ... x86_64`
- `zig version` → `0.17.0`
- `sha256(kynox.img)` at this commit → `8293bd72be9c1234cfcd8ee6d0a4a1615188b862823a27fbff4cc54c7934c1e3`
- Installing the missing pieces is not possible here: the sandbox runs as an
  unprivileged user (`apt-get update` fails with `Permission denied` on
  `/var/lib/apt/lists/partial`) and outbound access is restricted to a small
  allowlist; `http://archive.ubuntu.com/ubuntu/` answers with an empty reply.

**Nothing was simulated.** No serial log, screenshot or marker was invented,
and no QEMU suite is counted as passing anywhere in the documentation.

## 6. What a real run must record

For each of the three targets, keep in a new dated file under
`docs/validation/`:

1. environment: `uname -a`, `zig version`, `qemu-system-x86_64 --version`,
   OVMF package version and the exact firmware paths;
2. image identity: `sha256sum zig-out/bin/kynox.img`, the commit hash, and the
   build command;
3. the exact command line and the full VM configuration;
4. exit code, and the serial log and QEMU stderr as artifacts (not summaries);
   trim secrets, never edit markers;
5. the list of missing markers when it fails, verbatim;
6. for the interactive test, the PPM frames and the comparison results of
   `tests/integration/compare-framebuffer.py` / `compare-presentation.py`;
7. a short diagnosis: was the failure in the loader, the handoff, the kernel,
   a driver, or the test itself.

Only after a green, recorded run may the affected subsystems be described as
validated, and only then may `docs/PROJECT_STATUS.md` percentages move.

## 7. Known limits of the procedure itself

- One vCPU: the AP path is exercised, but SMP behaviour is not.
- `q35` with `virtio-blk-pci` only: no other chipset, device model or real
  hardware is covered.
- `-display none` plus `screendump`: proves the framebuffer was written, not
  that a human sees a correct desktop.
- Timeout-based termination: a slow host can trip the deadline; raise
  `--timeout` and record that it was raised.
- No CI: the run depends on the operator having QEMU and OVMF installed.
