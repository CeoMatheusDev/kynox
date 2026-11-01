# Kernel core fixes — 2026-11-01

- Status: **implementation record**. It describes what the tree does now, with
  the command that was executed and the result. It is not a plan, it claims no
  runtime behaviour, and it does not rewrite the audit it follows.
- Companion: [`2026-10-31-kernel-core-audit.md`](2026-10-31-kernel-core-audit.md)
  (read-only audit at `343e9fb`) and
  [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md)
  (the plan, which keeps its own wording: it records the initial state, not this
  record).
- Scope: the ranked defects of the audit §10 that could be closed without a
  hypervisor, plus the two build breakages that the tree carried.
- Not in scope: anything that needs a QEMU/OVMF run to be called done. **No
  runtime statement below is an observation**; the environment had no
  `qemu-system-x86_64` and no OVMF firmware, exactly as on 2026-10-31.

## 0. What was executed

| Command | Result |
|---|---|
| `zig version` | `0.17.0` |
| `zig build` | success — image written (`zig-out/bin/kynox.img`, 128 MiB, 32 731 clusters) |
| `zig build test --summary all` (fresh cache) | success — **49/49 steps, 736/736 tests**, 23 artifacts |
| `zig build docs-check` | success — every relative link resolves |

The 736 tests are the sum of what the artifacts report, measured in this
session: kvdi 173 · fs-loader 154 · arch **144** · shared 64 · kernel 22 ·
user-composition 22 · security **22** · damage 15 · version 13 ·
keyboard-motion 13 · kpk 9 · compositor 9 · sdk 8 · docs-conformance 22 ·
abi-conformance 7 · kex 7 · display 7 · ipc 6 · raster 5 · keyboard 4 ·
block-api 4 · ai 3 · boot-markers-conformance 3.

## 1. The tree did not build its own test suite

Two defects at `c010084`, both found by running the command the project
documents rather than by reading it:

1. `kernel/arch/x86_64/fpu.zig` used unnamed inline-assembly operands
   (`: "{ecx}" (0)`). Under Zig 0.17.0 every operand needs a name, so
   `arch-tests` did not compile and **every test in the architecture artifact
   was absent from the suite** — including the paging, ACPI, SMP and PCI tests
   that the status inventory counted.
2. `kernel/arch/x86_64/paging.zig` imported `../../memory/physical.zig` from
   inside `reclaimPhysicalPages`, which is outside the module path of the test
   root. The import was also an inverted dependency: the architecture layer
   reaching into the memory manager.

The status inventory recorded **716** tests for a tree whose architecture
artifact could not compile. That is the class of error the project forbids — a
count of tests that were present, not of tests that ran. The corrected, measured
number for this snapshot is **736**, and the architecture artifact alone reports
**144**.

## 2. Ranked defects closed

| # | Defect (audit §10) | What changed | Evidence |
|---|---|---|---|
| 4 | Unmap never frees frames | `paging.Flags.owned` (bit 9, software) records whether the space owns the frame; `takeOwnership` sets it after a successful load; `unmapUserPageIn` returns an owned frame and leaves a borrowed one; a refusal (`error.ReleaseUnavailable`) preserves the entry instead of losing the page | `arch-tests`: "unmapping an owned page returns it and unmapping a borrowed one does not", "an owned page is not removed when nothing can return it" (host) |
| 3 (part) | 8 static spaces, no destruction | `destroyAddressSpaceReal` releases the owned frames, clears the root, the PDPT, the PD and the PT, forgets the active space and frees the slot; `createAddressSpace` reuses a free slot and grows a per-slot generation; `spaceByIdentity(id, generation)` refuses a stale identity; `liveSpaceCount` and `spaces_created` expose the state | `arch-tests`: "a destroyed space returns its slot and grows the generation", "releasing the window returns the pages of the user to the manager", "destroying the space clears the private chain and every table" (host) |
| 5 | Capability table cannot be freed | `capability.destroy` clears the entry **before** walking the sets, `destroySubject`, `releaseProcess` (releases the set and destroys the capabilities that named the dead process), `removeFromSet` shared with `revoke`; `process.reapFull` calls it; the no-op `security.revokeCapabilities` is gone | `security-tests`: "a destroyed capability is taken from every holder and the entry is reused", "the table survives more capabilities than it has entries" (20 cycles over 16 entries), "reaping a process releases its set and the capabilities that named it", "destroying the capabilities of a subject removes every handle of it" (host) |
| 6 | No interrupt registration API | New `kernel/arch/x86_64/interrupt_registry.zig`: one owner per line, refusal of a second registration, `unregister`, per-line counters, `unhandledCount` for spurious lines, and a dispatcher that is the only writer of the counters. `interrupt.zig` re-exports the API and dispatches through it; the kernel registers the 8254 and the PS/2 lines at boot, before interrupts are enabled | `arch-tests`: 5 registry tests (dispatch, refusal, out-of-range vector, spurious accounting, per-line slots) (host). **The dispatch path itself has never run** |
| 7 | `apic` ↔ `timer` import cycle | `apic.zig` imported `timer.zig` without using a single symbol; the import is gone. The dependency is now one-way: `timer` programs the local timer through `apic` | build (no test can assert an import graph) |
| 11 | `net_transmit()` returns success without transmitting | `net_transmit` returns `error.NotImplemented`; the contract is stated in the file, and an explicit test asserts the error | `arch-tests`: "transmitting without a driver is an explicit error, never a success" (host) |
| 15 | Dead files and a dead constant | `arch/x86_64/elf_compat.zig`, `fs/dir_entry.zig` and `fs/test_ramfs_runner.zig` deleted (`git rm`); the last one did not compile at all (it referenced `ramfs.RamFS`, which does not exist) and its two tests were in no test root; `paging.window_pages` removed — it contradicted `shared/usermode.zig` | build |
| C.6 | Two tick sources | `timer.TickSource` + `selectTickSource`: exactly one clock counts the tick and drives the scheduler. Both interrupt paths ask the policy before they preempt; `initApicTimer` still calibrates the local APIC timer but leaves it **disarmed** while the 8254 owns the tick; the boot log prints the chosen source | `arch-tests`: "only the selected source counts the tick and drives the scheduler", "the two clocks together never count twice for one period" (host) |

Two smaller things that the same work removed: the tick body no longer lives
inside the vector `switch` in `interrupt.zig` (the kernel registers the 8254
handler and the PS/2 handler as policies of its own), and `virtio_net.zig` is
now part of a test root — its ten helper tests had never been compiled.

## 3. What is still open, and why

| # | Defect | Blocked on |
|---|---|---|
| 1 | Scheduler has no synchronisation and pretends to be per-CPU | K3; needs a lock and per-CPU ownership, which needs a runtime to validate |
| 2 | Single global TSS with one `rsp0` | K0 step 3; a mistake in the fault path turns a `#GP` into a triple fault, and there is no way to observe it here |
| 8 | FPU/SSE state not saved on the context switch | K3; `fpu.zig` has the instructions, but changing `task.s` without a boot to test it is a blind change to every context switch |
| 9 | `main.zig` mixes bring-up, demo and self-test | K0 step 1–2 (phase table); the largest structural item of the roadmap |
| 10 | VFS hardwired to RamFS | K10 |
| 12 | Legacy VirtIO duplicate kept alive by tests | K7 (ADR-0002 step 3); deleting it now would remove 15 live host tests before the KVDI coverage that replaces them exists |
| 13, 14 | TOCTOU between `isUserRange` and the copy; no `copy_*_user` | K6 |

The dispatch path of the interrupt registry, the released frame of an unmapped
page, the reuse of an address-space slot and the single tick source are code and
host tests only. They become claims about the running system at the moment
`docs/validation/qemu.md` records a boot, and not before.

## 4. Documentation corrected with the code

- `docs/PROJECT_STATUS.md` and `docs/PROJECT_STATUS.json`: new snapshot, the
  measured test counts, the closed defects with their evidence, the still-open
  ones, and `virtual_memory` raised from 45% to 50% (frames are returned, the
  space is destroyed and its slot is reused, each with host tests).
- `README.md`: the progress table and the limitations follow the inventory.
- `docs/architecture/memory-management.md`: the "current state" table now says
  which pages unmap returns (`Flags.owned`) and that a destroyed space returns
  its slot.
- `CHANGELOG.md`: an entry under `Unreleased` that names the commands and the
  result, and does not claim a boot.
