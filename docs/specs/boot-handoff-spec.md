# KNB → KNK boot handoff contract — v1

> Normative description of the structure that the Kynox Native Boot loader
> (**KNB**) hands to the Kynox Nucleus Kernel (**KNK**).
>
> Source of truth: [`shared/handoff.zig`](../../shared/handoff.zig). This
> document was written from the code on 2026-10-31 and must be updated with it.
> If the two disagree, the code and its tests win, and this document is a bug.

## 1. Parties and transport

| Side | Implementation | Responsibility |
|---|---|---|
| KNB | `boot/uefi/main.zig`, `boot/uefi/knb/` | locate the kernel file, place it, build the handoff, leave firmware, transfer control |
| KNK | `kernel/arch/x86_64/entry.s`, `kernel/main.zig` | validate the handoff, copy firmware data it still needs, take ownership of the machine |

The handoff structure lives in memory that survives `ExitBootServices`
(allocated by KNB as `runtime_services_data`). KNB passes its **physical**
address in `RDI` and jumps to the kernel entry point.

Register contract at `kynox_kernel_entry`:

| Register | Content |
|---|---|
| `RDI` | physical address of `BootHandoff` |
| `RSI` | reserved, currently 0 — consumers must not rely on it |
| `RSP` | not usable: the kernel loads its own stack (`kynox_boot_stack`, 64 KiB in `.bss`) and re-aligns to 16 bytes |
| Interrupts | disabled on entry (`cli` by KNB; kernel enables them when it installs its own handlers) |

Because the kernel is placed at a physical address chosen at boot, the
address carried in `RDI` is a physical address inside the identity-mapped
region (below 4 GiB). KNB refuses to hand over a handoff/memory-map buffer at
or above that limit (`error.HandoffOutsideIdentityMapping`).

## 2. Versioning rules

- `handoff_magic = 0x564F_5259_4E42_4F54` (`"KYNOXBOT"`), first field checked.
- `handoff_version = 1`; the kernel rejects any other value with
  `error.UnsupportedVersion`. There is no negotiation: KNB and KNK are built
  from the same tree and must agree exactly.
- `header_size` allows forward extension: the kernel requires
  `header_size >= @sizeOf(BootHandoff)` with the size it was built against
  (`error.Truncated` otherwise). A future revision may append fields; removing
  or reordering fields is a version bump.
- All fields are `extern` and sized for the SysV AMD64 ABI; the structure must
  stay representation-compatible between the two compilations (same Zig
  version, same target layout).

## 3. Structure layout (version 1)

```zig
BootHandoff = extern struct {
    magic: u64,                    // handoff_magic
    version: u32,                  // handoff_version
    header_size: u32,              // size of this structure in bytes
    flags: u64,                    // bit mask, see §4
    handoff_address: u64,          // physical address of this structure
    memory_map_address: u64,       // physical address of the descriptor array
    memory_map_entries: u32,       // number of valid descriptors
    memory_map_stride: u32,        // bytes between descriptors (must be 40)
    framebuffer: FramebufferInfo,  // valid only with flag_framebuffer
    kernel_base: u64,              // first physical byte of the image
    kernel_end: u64,               // first physical byte past the image
    kernel_entry: u64,             // physical entry point of the image
    kernel_stack_top: u64,         // 0 in v1: stack belongs to the kernel image
    kernel_stack_bottom: u64,      // 0 in v1
    acpi_rsdp_address: u64,        // valid only with flag_acpi_rsdp
    boot_processor_id: u32,        // 0 in v1
    processor_count: u32,          // 1 in v1
    firmware_size: u64,            // UEFI system table header size
    firmware_revision: u64,        // UEFI system table header revision
}
```

`FramebufferInfo`:

```zig
FramebufferInfo = extern struct {
    base: u64,            // physical base of the linear framebuffer
    size: u64,            // region size in bytes
    width: u32,           // visible width in pixels
    height: u32,          // visible height in pixels
    pitch: u32,           // bytes per row
    bits_per_pixel: u32,
    pixel_format: u32,    // 0 = rgb32, 1 = bgr32, 0xFFFFFFFF = unknown
    red_mask: u32, green_mask: u32, blue_mask: u32,
    red_shift: u8, green_shift: u8, blue_shift: u8,
    _reserved: [3]u8,     // zero
}
```

`MemoryDescriptor` (40 bytes, `memory_descriptor_size`):

```zig
MemoryDescriptor = extern struct {
    memory_type: u32,   // EFI_MEMORY_TYPE-compatible, see below
    _reserved0: u32,    // zero
    physical_start: u64,
    virtual_start: u64, // diagnostics only; the PMM ignores it
    page_count: u64,    // in 4 KiB pages
    attributes: u64,    // EFI attribute bits
}
```

Only `memory_type` values `conventional` (7) and `persistent_memory` (14)
count as usable RAM (`MemoryType.isUsableRam()`); everything else must be
excluded from the physical allocator. Numeric values are deliberately
EFI-compatible so KNB can transfer them verbatim.

## 4. Flags

| Flag | Bit | Meaning when set |
|---|---:|---|
| `flag_framebuffer` | 0 | `framebuffer` is valid |
| `flag_kernel_from_disk` | 1 | the image was read from the ESP and validated as ELF64 |
| `flag_memory_map_final` | 2 | the map was captured immediately before `ExitBootServices` |
| `flag_identity_mapped` | 3 | firmware identity-mapped the first 4 GiB; physical == virtual at handoff |
| `flag_acpi_rsdp` | 4 | `acpi_rsdp_address` is valid |

## 5. Validation performed by the kernel

`handoff.validate()` runs before anything else touches the structure:

| Check | Error |
|---|---|
| `magic == handoff_magic` | `BadMagic` |
| `version == handoff_version` | `UnsupportedVersion` |
| `header_size >= @sizeOf(BootHandoff)` | `Truncated` |
| `memory_map_entries != 0` ⇒ `memory_map_address != 0` | `MissingMemoryMap` |
| `memory_map_entries != 0` ⇒ `memory_map_stride == 40` | `BadMemoryMapStride` |

On any failure the kernel prints `[KNK] FATAL: invalid handoff: <error>` and
halts. It then verifies that `boot.kernel_entry` equals the address of
`kynox_kernel_entry` in its own image and halts on mismatch
(`[KNK] FATAL: entry mismatch`), so a loader that jumps to a stale image is
detected before any subsystem initializes.

The kernel copies the handoff **and the descriptor array** into its own
storage (`copyBootInformation`) because the firmware's page tables are
replaced later in the boot. The copy ignores descriptors whose address is at
or above `identity_mapped_limit`.

## 6. Sequence performed by KNB

1. Disable the firmware watchdog (non-fatal if unsupported).
2. Discover the linear framebuffer (`knb/framebuffer.zig`); on failure the
   boot continues without `flag_framebuffer`.
3. Allocate the scratch buffer (`loader_code`) and the published map buffer
   (`runtime_services_data`, 1024 descriptors max), fetch a provisional map.
4. Open the boot volume, read `\boot\kynoxk.elf`, and plan the load
   (`shared/elf64.zig`: segments, bounds, relative relocations).
5. Choose a load bias: prefer a 2 MiB-aligned region ≥ 1 MiB for future large
   pages, fall back to 4 KiB alignment. `position independent` images are
   placed by bias, fixed images by their link address.
6. Copy each `PT_LOAD` segment, zero the non-file-backed tail, apply RELA
   relative relocations; verify each segment end is below 4 GiB and that the
   firmware honored the requested allocation address.
7. Allocate the handoff (`runtime_services_data`), read the ACPI RSDP pointer
   from the configuration table (before leaving firmware), reject a handoff or
   map buffer at/above 4 GiB.
8. Re-fetch the final memory map and call `ExitBootServices`; retry (up to 8
   attempts) when the firmware reports the map key is stale.
9. Detach the firmware console, then `cli; mov RDI, handoff; jmp entry`.

## 7. Known limitations of v1

- `kernel_stack_top`/`kernel_stack_bottom` are 0: the kernel owns its stack in
  the image, so KNB cannot describe it. A future revision either fills these
  or removes them (breaking change ⇒ version 2).
- `processor_count` is hard-coded to 1 and `boot_processor_id` to 0, even
  though KNB could read them from the firmware. SMP bring-up therefore relies
  on kernel-side discovery, which today is limited to LAPIC enumeration.
- `acpi_rsdp_address` is consumed by `discoverAcpi` in `kernel/main.zig`, which
  walks RSDP → XSDT/RSDT → MADT and installs the validated local APIC base
  (see `docs/specs/acpi-platform.md`). When the table is missing, corrupt or
  unusable, the kernel logs the reason and keeps `0xFEE00000` (finding A-03,
  resolved in part: the I/O APIC is recorded, not programmed).
- There is no integrity check (checksum/signature) over the handoff; trust is
  implicit because both sides ship in the same image.

## 8. Change checklist for a revision

1. Bump `handoff_version` for any incompatible layout change.
2. Update `BootHandoff`, KNB producer, KNK consumer, and this document together.
3. Extend the tests in `shared/handoff.zig` (magic/version/size/stride) and add
   a test for whatever new field the kernel acts on.
4. Re-run `zig build test` and a QEMU boot; record both results in
   `docs/PROJECT_STATUS.*` and in the release notes.
