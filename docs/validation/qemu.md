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
`--image=`, `--timeout=`, `--evidence-dir=<path>` and, for the boot test,
`--verify-kvdi-log=<path>`.

## 3a. What a run leaves behind

Without `--evidence-dir` a run is self-contained: the script creates a
temporary directory and removes it on exit, so nothing survives. With
`--evidence-dir` (or `zig build qemu-test -Devidence-dir=<path>`, whose default
is `docs/validation/logs`) the script writes, **on every exit path** — a pass, a
failed assertion, a missing firmware, a missing emulator:

| File | Content |
|---|---|
| `summary.txt` | date, result and exit status, duration, timeout, image, firmware, emulator, and one `failed_check:` line per failed assertion |
| `serial.log` | the whole serial console of the boot |
| `qemu.stderr` (boot, `boot1`/`boot2` in the storage test) | the standard error of the emulator |
| `presentation.ppm` (boot) | the screenshot taken while the compositor holds the frame |

The summary is written first, so it exists even when the run produced no
console at all — the case in which it matters most. On failure the last 20
lines of the console are also repeated in the step log, because the annotation
that the CI publishes carries only the tail of it.

The files of a run are ignored by Git (`.gitignore`): they are evidence of one
run, not of the tree. `docs/validation/logs/` keeps the records a human wrote
into it.

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

## 8. Provisioning attempt — 2026-10-31 (stage 1 of the runtime task)

The suite was re-run against the tree of this date, and an isolated
provisioning script was written so that a future environment (or a CI runner)
can obtain the pieces without touching a system directory:

- `scripts/provision-qemu.sh` — downloads a static `qemu-system-x86_64`
  (ziglang/qemu-static release) and the OVMF firmware (rust-osdev/ovmf-prebuilt)
  into `.tools/` (ignored by Git), verifies the archives, and prints the
  `OVMF_CODE`/`OVMF_VARS`/`PATH` exports to use. It never writes outside the
  repository and never needs root. `--check` reports what is already present.
- `docs/validation/logs/2026-10-31-qemu-attempt.txt` — verbatim log of the
  three suites and of the provisioning attempt.

**Result: still not executed.** The three targets fail as before
(`no OVMF firmware found`, exit 2). The provisioning script fails one step
earlier, at the download:

```
provision-qemu: download failed: … curl: (35) OpenSSL SSL_connect:
SSL_ERROR_SYSCALL in connection to release-assets.githubusercontent.com:443
```

`api.github.com` answers (200), but release assets are served from
`release-assets.githubusercontent.com`, which this sandbox cannot reach; the
same happens for `objects.githubusercontent.com`. No package manager is
available (unprivileged user), there is no `qemu-system-x86_64`, no `/dev/kvm`
and no `vmx`/`svm` CPU flag, so a source build is impossible here as well.

**Consequences, stated plainly:**

- no serial log exists for this tree, so no subsystem gained runtime evidence;
- `-Dioapic-delivery=true` compiles, but no boot proves it delivers an
  interrupt;
- the IOAPIC entries are programmed masked, so the compiled default keeps the
  8259 as the only delivery path;
- the CI workflow added on this date installs QEMU and OVMF on the runner and
  fails loudly when it cannot; **it has not run yet**, so it is not evidence
  either.
