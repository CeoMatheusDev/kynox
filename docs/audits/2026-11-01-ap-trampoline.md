# The trampoline of the APs — 2026-11-01

- Status: **implementation record**. It states what the tree does now, with the
  commands that were executed and their results. It claims no runtime behaviour:
  no AP has ever answered a startup IPI here.
- Companions:
  [`2026-11-01-idle-task-and-per-cpu-tss.md`](2026-11-01-idle-task-and-per-cpu-tss.md)
  (the per-CPU segment that the AP installs, and the idle task),
  [`2026-11-01-scheduler-lock.md`](2026-11-01-scheduler-lock.md) (the lock the
  AP will contend) and [`2026-10-31-kernel-core-audit.md`](2026-10-31-kernel-core-audit.md)
  §A.9 (SMP and AP startup) and §A.10 (per-CPU data).
- Scope: the block of `ap_trampoline.s` as data — where it goes, who writes it,
  in which order — and the startup path that uses it.
- Not in scope: an AP on the scheduler, per-CPU run queues, IPIs beyond
  INIT/SIPI, and a run on a machine with more than one processor.

## 0. What was executed

| Command | Result |
|---|---|
| `zig build` | success — kernel image and `kynox.img` (128 MiB) written |
| `zig build test --summary all` (fresh cache) | success — **52/52 steps, 815/815 tests**, 24 artifacts |
| `zig build docs-check` | success — every link resolves, every document classified |

`arch-tests` moved from 146 to **155** (six tests of the block, three of the
startup path). The total moved from 806 to 815.

## 1. The defect this closes

> **The audit, §A.9:** the trampoline exists and is never copied. `startAps()`
> refuses, so no AP has ever run. **The risk:** the moment somebody "just sends
> the IPI", an AP executes whatever is at the vector.

The refusal was honest but it was also the whole story: the assembly had no
caller, the fields it reads (`ready`, GDT base, CR3, stack, CPU number, entry)
were filled by nobody, and the code that filled them had no test. Now:

| Piece | Before | Now |
|---|---|---|
| copy below 1 MiB | none | `smp.prepareTrampoline(address, cr3, efer_bits)`, called at boot from `installApTrampoline()` |
| identity mapping of the page | none | `paging.mapKernelPage(0x8000, 0x8000)` at boot (`AlreadyMapped` is accepted) |
| fields | nobody wrote them | `ap_trampoline.install` (per boot) and `ap_trampoline.arm` (per AP) |
| `ready` ordering | a comment | cleared at copy, cleared again before each AP, written **last** |
| placement | assumed | `memmap.isUsableRange` at boot + `validatePlacement` in the module |
| EFER of the AP | `LME` only, hard-coded in the assembly | the bits of the BSP (`LME`, and `NXE` when the BSP enabled it) written into the block |

## 2. `kernel/arch/x86_64/ap_trampoline.zig`: the block as data

The assembly exports one symbol per field. The module reads them once
(`kernelLayout()`), which means a field added to the assembly shows up in the
Zig side without an edit, and refuses anything that does not fit:

| Check | Refusal |
|---|---|
| every field ends inside the block, aligned for its width | `error.FieldOutside` |
| block size is non-zero and fits in a page | `error.BadPlacement` |
| the page is below 1 MiB, page-aligned, and its vector fits in the 8 bits of the SIPI | `error.BadPlacement` |
| the destination holds the block | `error.DestinationTooSmall` |
| the source **is** the block (same size) | `error.SourceSizeMismatch` |
| the 32-bit fields (GDT base, far pointer, CR3) are not truncated | `error.ValueTooLarge` |

The two entry points are the two moments the block has:

**`install(dest, source, layout, params)`** — copies the assembly into the low
page and writes what is the same for every AP: the base of the temporary GDT,
the target of the far jump into 32-bit code, CR3, the EFER bits, and the address
of `kynox_ap_entry`. It clears `ready` **first** and leaves it clear: the copy is
complete for the BSP, not for an AP.

**`arm(dest, layout, {stack_top, cpu_id})`** — the per-AP part, called for one AP
at a time, because the block is a single page shared by all of them:

```text
ready = 0            ← an AP cannot read the stack of the AP before it
stack = <its stack>
cpu_id = <its number>
ready = 1            ← last store: everything it reads is already written
```

The stores are `volatile` and typed `align(1)`: the order is the contract (the AP
polls the word from real mode), and the base of the pseudo-descriptor of the GDT
is a 32-bit field at a 2-byte offset, where an "I am aligned" claim would be a
lie the compiler may profit from.

## 3. The AP that could not have worked anyway: `EFER`

The assembly enabled long mode with a hard-coded `LME` bit:

```asm
movl $0xC0000080, %ecx
rdmsr
orl $0x100, %eax      ; LME only
wrmsr
```

The kernel enables `NXE` (`cpu.enableNoExecute`) and marks pages without
execution (`paging.Flags.no_execute` on device pages and kernel data). An entry
of the page tables with the NXE bit while `EFER.NXE` is clear is a **reserved
bit**, and the fault happens inside the trampoline, in protected mode, **with no
IDT**: a triple fault with no message, on a processor that has no business
faulting.

The bits are not hard-coded in either direction now: the BSP reads its own
`EFER` (`cpu.modeBits()` = `LME | NXE` as the processor accepted them) and the
block carries them. A machine without the feature gets `LME` only, which is
exactly the state its page tables are in.

## 4. The two numbering systems

The entry of an AP took `cpu_id` and indexed `ap_stacks[cpu_id - 1]`. That is
correct only when the BSP is entry **0** of the CPU table — and the table is
built from the MADT, where the BSP can be any entry. With the BSP at entry 1, an
AP that received `cpu_id = 1` would write the stack pointer of the BSP's slot and
register itself with the identity of the BSP.

There is one numbering now: the **index in the CPU table**, the same number
`cpuId()` returns, that `configureFromMadt` assigns, that `armTrampolineFor`
passes in RDI and that indexes `ap_stacks`/`ap_stack_top`. A CPU number the table
cannot hold is refused before any IPI (`armTrampolineFor`), and the entry itself
refuses one above `max_cpus`.

The AP also stopped using a bare `hlt` in its loop: it arrives with interrupts
disabled, so `hlt` froze it for ever and it could not even receive the IPI that
would wake it. It waits with `sti; hlt` (`cpu.waitForInterrupt`).

## 5. The path at boot

```text
installSmp()
  ├─ map the local APIC, enable it, calibrate the local timer
  ├─ smp.initAps()                        one stack per logical CPU
  ├─ installApTrampoline()
  │    ├─ memmap.isUsableRange(0x8000, 4096)      ← the map may say "reserved"
  │    ├─ paging.mapKernelPage(0x8000, 0x8000)    ← the AP keeps the physical address
  │    ├─ smp.prepareTrampoline(0x8000, root, efer)
  │    │    └─ trampoline.install(...)            ← copy + fields, ready = 0
  │    └─ log: bytes, vector, entry, EFER bits
  ├─ configureFromMadt(...)
  └─ smp.startAps()
       └─ per AP: armTrampolineFor(index, stack) → INIT → SIPI ×2 → bounded wait
```

Each refusal is a separate line, because the alternative is a boot that says
"no AP" without saying which of four preconditions failed.

## 6. The tests added (nine)

| Artifact | Test | Asserts |
|---|---|---|
| `arch-tests` (6) | the vector of the startup IPI is the page of the block | `base == vector << 12`, vector < 0x100, below 1 MiB |
| | a placement that a startup IPI cannot reach is refused | above 1 MiB, unaligned, larger than a page, empty, and the last page a vector can name |
| | the copy carries the fields of every AP but leaves `ready` cleared | GDT base (at +2 of the pseudo-descriptor), far pointer, CR3, EFER, entry; the rest of the block is byte-identical |
| | arming one AP writes its stack and number and releases it last | two APs in a row, and arming above the destination is refused |
| | a layout whose fields fall outside the block is refused | a field past the end, an unaligned 64-bit field, a block larger than a page, short destination, wrong source |
| | the 32-bit fields refuse a bigger value | GDT base, far pointer and CR3 above 4 GiB |
| `arch-tests` (3) | the trampoline is not published until the block is copied | `startAps`'s precondition, and `arm` refused |
| | publishing an address does not arm an AP without a layout | an announcement is not a copy; a CPU index above `max_cpus` is refused |
| | the stack of an AP is indexed by its number in the table | one entry per logical CPU, 16-byte aligned, equal to the top of its own array |

## 7. What is still open

| Item | Why |
|---|---|
| An AP that answers the IPI | There is no `qemu-system-x86_64` and no OVMF in this environment. The copy, the fields and the order are code and host tests; "the AP started" is a claim about a machine, and this tree still has none |
| The AP on the scheduler | The AP installs its segment, marks itself online and waits (`sti; hlt`). It does not take a task, and the run queues are still one set |
| IPIs beyond INIT/SIPI | Reschedule and TLB shootdown need per-CPU queues that do not exist yet |
| The EBDA | The page is chosen by the vector (0x08) and checked against the firmware map; it is not checked against the EBDA pointer at `0x40E`, which no boot here has ever read |

## 8. Documentation updated with the code

- `docs/PROJECT_STATUS.{md,json}`: `smp` **30% → 44%**, the measured counts (815,
  arch 155), the limitation lists ("the trampoline is never copied" is gone;
  "no AP has answered" stays), `K-01`, and the inventory row of this record.
- `README.md`: the SMP row, the limitation list and the test counts.
- `docs/ai/context-pack.md`: the state of the tree in one page.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: the annotations of K0 and K2.
- `CHANGELOG.md`: the entry of this round.
