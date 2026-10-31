# ACPI platform discovery

Status: implemented in the kernel boot path, unit-tested on the host, **not yet
validated under QEMU or on real hardware**. This document describes what the
kernel actually does today; anything not listed here is not implemented.

Related: [`boot-handoff-spec.md`](boot-handoff-spec.md) (`flag_acpi_rsdp`,
`acpi_rsdp_address`), [`VERSIONING.md`](../VERSIONING.md).

## 1. What the kernel consumes

| Table | Use |
|---|---|
| RSDP | root pointer, published by the firmware, captured by the loader |
| RSDT (ACPI 1.0) | container of 32-bit table addresses |
| XSDT (ACPI 2.0+) | container of 64-bit table addresses, preferred |
| MADT | processor list, local APIC address, I/O APIC list, interrupt source overrides |

The kernel does **not** read FADT, MCFG, DSDT/SSDT or any AML. PCI is still
discovered by configuration-space scan, not by MCFG.

## 2. Discovery chain

```
BootHandoff.acpi_rsdp_address  (flag_acpi_rsdp set by the loader)
        │
        ├─ read 36 bytes → validateRsdpBase (20-byte checksum, signature, revision ≤ 2)
        │       └─ revision ≥ 2 → validateRsdpExtended (36-byte checksum) → XSDT address
        │       └─ otherwise, or XSDT address = 0 → RSDT address
        │
        ├─ read container (36-byte header + entries) → checksum → signature (XSDT/RSDT)
        │       └─ for every 8-byte (XSDT) or 4-byte (RSDT) entry:
        │              read the pointed table; an unreadable entry is skipped
        │              a table whose signature is `APIC` is the MADT
        │
        └─ read MADT → checksum → parseMadt
```

`parseMadt` walks the variable-length entries after the 44-byte MADT header:

| Type | Entry | Kept |
|---:|---|---|
| 0 | Processor Local APIC | yes, `enabled` from flags bit 0, up to `smp.max_cpus` |
| 1 | I/O APIC | yes, up to `max_io_apics` (4) |
| 2 | Interrupt Source Override | yes, up to `max_isa_overrides` (8) |
| 5 | Local APIC Address Override | yes, replaces the 32-bit header field |
| 9 | x2APIC | yes, processor with a 32-bit id |
| other | — | skipped, still length-validated |

Every entry must declare a length of at least its fixed part; a shorter entry
aborts the parse with `error.InvalidLength`. Overflow past the fixed arrays sets
`truncated`, `io_apic_overflow` or `override_overflow` instead of writing out of
bounds, and the kernel logs it.

## 3. Validation before use

| Value | Rules | Failure |
|---|---|---|
| RSDP address | non-zero, inside the identity map | `error.UnreadableTable` |
| Table checksum | sum of all declared bytes ≡ 0 | `error.InvalidChecksum` |
| Table length | ≥ 36, ≤ 1 MiB, ≥ header size read | `error.InvalidLength` |
| Local APIC address | non-zero, page-aligned, < 4 GiB | `Madt.lapicBase()` returns `null` |
| I/O APIC address | non-zero, page-aligned, < 4 GiB | entry discarded, logged |

`apic.setBase` repeats the local-APIC checks and returns `error.NullAddress`,
`error.Misaligned` or `error.OutOfRange`; a refused address never reaches MMIO.
A rejected value leaves the previous base untouched.

## 4. Fallback

The kernel never halts because of ACPI. Each failure mode produces one serial
line with the reason and the kernel continues with `apic.default_base`
(`0xFEE0_0000`):

| Situation | Serial line |
|---|---|
| loader did not publish an RSDP | `acpi: no RSDP from the loader; APIC base stays at ...` |
| any discovery error | `acpi: MADT unavailable (<error>); APIC base stays at ...` |
| MADT without a usable LAPIC address | `acpi: no usable local APIC address, base stays at ...` |
| I/O APIC entry rejected | `acpi: IOAPIC id=N at 0x... ignored (unusable address)` |
| no usable I/O APIC | `acpi: no usable IOAPIC; interrupts stay on the 8259/APIC local` |

The fallback is a documented default, not a silent guess: the boot log always
states which path was taken.

## 5. Where the read happens

`discoverAcpi` runs after `installMemoryManager` and **before**
`buildPageTables`/`activatePageTables`. The firmware identity mapping that
describes ACPI memory only exists while the firmware page tables are active;
after CR3 is replaced the kernel maps only its own image and the framebuffer.

The table source (`AcpiMemory`) refuses addresses at or above
`handoff.identity_mapped_limit` and refuses ranges that would cross it, so a
corrupt length cannot make the kernel read outside the addressable window.

## 6. What is stored

`PlatformInfo` keeps the MADT address, the processor count, the local APIC base
in use, the accepted I/O APICs and the override count. Nothing else from ACPI is
retained: the module keeps no pointer into firmware memory.

## 7. Not implemented

- **I/O APIC programming.** The I/O APIC addresses are recorded and validated,
  but no redirection-table entry is written; interrupts still arrive through the
  8259 PIC and the local APIC.
- **Interrupt source overrides in routing.** The overrides are parsed and
  counted; they do not change any routing yet.
- **MADT processor list as the SMP source of truth.** `smp` still uses the AP
  parking protocol it had; the MADT count is reported, not used to start APs.
- **NMI, LAPIC overrides beyond type 5, SRAT/SLIT/NUMA, MCFG, FADT.**
- **Hardware/QEMU validation.** No QEMU or OVMF is available in the development
  environment (audit finding A-02), so this path is compiled and unit-tested
  only.

## 8. I/O APIC programming (2026-10-31)

Discovery is not routing, and this section keeps the two apart.

**What the module does.** `kernel/arch/x86_64/ioapic.zig` reads the
identification and version registers of one controller, decodes the maximum
redirection entry from the version register (bits 16..23 hold *count minus
one*), and encodes/decodes a 64-bit redirection entry: vector, delivery mode
(fixed/lowest/NMI/init/extINT), destination mode, polarity, trigger mode and
mask bit. `Controller.init` validates the base address before touching it and
rejects a controller whose version decode yields no entries.

**What the boot path does.** `kernel/main.zig::installIoApic` runs after the
page tables are active and after the local APIC is mapped:

1. it takes the **first usable I/O APIC** recorded from the MADT (already
   validated during discovery: nonzero, page-aligned, inside the identity
   window);
2. it maps the 0x20-byte MMIO window with `paging.mapDevicePage` — the device
   page, not the kernel image;
3. `Controller.init`, then `maskAll()`: every entry is masked before any of
   them is written;
4. it derives the route of each ISA line in use from `acpi.isaRoute(irq,
   overrides)` — the effective GSI (ISA identity when there is no override),
   polarity and trigger — and programs the entry with vector `32 + irq`,
   destination = BSP APIC id, **masked**;
5. it logs one line per line with `isa irq`, `gsi`, vector, polarity and
   trigger, so a wrong override is visible in the log rather than inferred.

**Delivery stays on the 8259** unless the build option `-Dioapic-delivery=true`
sets `kynox_config.ioapic_delivery`. With the option, the sequence is
`timer.disablePic()` (mask both 8259s) *then* unmask the entries; without it,
the entries stay masked and the log says so. The two controllers must never
forward the same line, and the 8259 path is the one with real boot history.

**End-of-interrupt.** `timer.endOfInterrupt(vector)` chooses the EOI target
from the same switch: the local APIC when the I/O APIC delivers, the 8259
otherwise. Sending an EOI to the wrong controller leaves the interrupt
controller waiting and blocks every later interrupt of that priority.

**Known limits.** Level-triggered lines need the source's EOI acknowledgement
(and, for PCI, the `0x0C` command port); only ISA edge/level lines derived from
the MADT are configured. No entry is programmed for the PCI GSI range, no
interrupt remapping (VT-d/AMD-Vi), no x2APIC MSI, no per-CPU distribution of
GSIs, and nothing here was executed on a hypervisor: the module and the boot
path are compiled and unit-tested, not validated by a recorded boot.

## 9. Processor table and AP startup (M0.5, host-only)

`kernel/arch/x86_64/smp.zig` builds its CPU table from the **enabled**
processors of the MADT (`configureFromMadt`), in table order, skipping
duplicates and capping at `max_cpus` (16). The BSP is the entry whose APIC id
matches the local APIC id, and its logical number is what `cpuId()` returns —
translated through the table, not assumed to be zero. A MADT that names no
processor leaves a single online BSP: boot never depends on a complete table.

`startAps()` refuses to send an IPI in two situations, and logs which:

- no AP was discovered (single-CPU machine);
- the trampoline has not been published below 1 MiB
  (`publishTrampoline`, no caller yet — the BSP does not copy
  `ap_trampoline.s` into low memory).

With both preconditions met, each AP gets INIT, then two SIPIs to the
trampoline page, and the BSP waits a bounded number of `pause` iterations for
`online`; an AP that does not answer is reported as such and stays
`initializing`. **No AP has ever been started in this tree**: the runtime
evidence is missing, so SMP remains `in_progress` and no SMP behaviour is
claimed.

## 10. Tests

`kernel/arch/x86_64/acpi.zig`, `ioapic.zig` and `smp.zig` are reachable from
the `arch-tests` artifact (`kernel/arch/x86_64/root.zig`). The suite builds
synthetic RSDP/XSDT/RSDT/MADT images and covers:

- checksum, signature and length rejection at each level;
- RSDT fallback for ACPI 1.0 and XSDT preference for revision 2 (two-level RSDP
  sealing: 20-byte and 36-byte checksums);
- corrupted XSDT checksum → `error.InvalidChecksum`;
- MADT absent → `error.NoMadt` (the discoverer never guesses);
- unreadable RSDP → `error.UnreadableTable`;
- I/O APIC and override parsing, entry-length rejection, overflow accounting;
- local-APIC and I/O-APIC address validation, including misalignment and the
  4 GiB limit;
- `apic.setBase`/`resetBase` behaviour and the specific error for each refusal;
- ISA routes: identity when there is no override, override GSI/polarity/trigger
  when there is, and a reserved (value 3) flag field falling back to the
  conforming high/edge encoding;
- redirection entries: vector/GSI bounds, low/high-word encoding, mask bit,
  destination placement, version decode and MMIO window size;
- the CPU table: MADT order, disabled and duplicate processors skipped, BSP
  chosen by APIC id, empty MADT leaving one online BSP, cap at `max_cpus`.

The discovery test uses an injected table source, so no page table or firmware
state is needed.
