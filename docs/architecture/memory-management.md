# Memory management model

- Status: **planning document** describing the target model and the current
  state. It does not describe capabilities that do not exist.
- Date: 2026-10-31.
- Related: [`kernel-internals.md`](kernel-internals.md),
  [`execution-model.md`](execution-model.md),
  [`platform-architecture.md`](platform-architecture.md) §4.3,
  [`../audits/2026-10-31-kernel-core-audit.md`](../audits/2026-10-31-kernel-core-audit.md) §B/§C,
  [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md) stages K1, K8.

## 1. Current state, precisely

| Component | File | Reality |
|---|---|---|
| Physical manager | `kernel/memory/physical.zig` | 4 KiB bitmaps for the addressable range, but the manager refuses to initialise above 4 GiB; host-tested; frees and invalidates TLB |
| Kernel page tables | `kernel/arch/x86_64/paging.zig` | four-level, maps the kernel, the 24 KiB user window and the 64 MiB DMA window; **never unmaps a frame** except in the DMA release path and the materialiser's failure path |
| Address spaces | `kernel/arch/x86_64/paging.zig` | 8 static slots, a per-slot process-window PDPT; **no destroy**, no teardown of the level-2 copy |
| Kernel heap | `kernel/memory/heap.zig` | arena allocator over a reserved region, no lock (single-threaded assumption), no stats beyond high-water |
| DMA | `kernel/memory/dma.zig` | 64 MiB identity window with a bitmap; allocate/free/release |
| Regions, demand paging, COW, file-backed pages, page cache | — | **not started** |
| IOMMU | — | **not started** |

Consequences that are not hypothetical:

1. A process that exits leaks its window and its frames. The address-space slot is
   reused, so the leak is bounded at 8 windows — but the physical frames are not
   reclaimed.
2. Because unmap never frees, nothing in the kernel can rely on the invariant
   "an unmapped page's frame is free". Reclaim logic cannot be written until this
   is fixed, which is why stage K2 precedes everything else.
3. `paging.window_pages` is 4 while the user-mode contract publishes 6 pages
   (`usermode.window_size = 0x6000`). The unused constant is dead code; the
   discrepancy is a latent off-by-two in any code that trusts the kernel's value.

## 2. Target model

Four layers, each with one responsibility:

```text
physical.zig     frames: allocate, free, reference-free accounting
  ↓
vmm.zig          address spaces: map, unmap, protect, regions, fault handling
  ↓
regions.zig      memory objects: anonymous, file-backed, device, stack, guard
  ↓
heap.zig         kernel allocations on top of a reserved window
```

### 2.1 Frames

- One frame = 4 KiB, identified by physical address, tracked by bitmap (the
  existing structure is adequate; no reason to replace it).
- Accounting: `free`, `used`, `reserved`, `pinned`, `cache`. The numbers are
  reported by the diagnostics interface.
- `free` requires that no mapping references the frame. The VMM satisfies this by
  being the only caller of `free` during unmap, after a TLB invalidation.
- Frames above 4 GiB: supported by initialising one bitmap per GiB region from the
  EFI memory map instead of rejecting the range. No new allocator algorithm.
- Double free is a detected error (bit already clear → counter + crash record in
  debug builds), not silent corruption.

### 2.2 Address spaces

An address space is an object, not a slot number:

```zig
pub const AddressSpace = struct {
    pml4_phys: u64,
    window: UserWindow,          // the syscall-window contract
    regions: RegionList,
    lock: SpinLock,
    refs: usize,
    id: u32,                     // stable identifier for diagnostics
};
```

- **Creation and destruction are symmetric.** `destroy` walks the regions,
  unmaps each page, frees anonymous frames, drops file references, frees the
  page-table pages, and returns the slot.
- **Slots stay** as a fixed array (a bounded kernel wants bounded metadata), but
  the slot is owned by the object and the object's lifetime is explicit. The
  8-slot ceiling is raised to a configurable number with a compile-time maximum;
  the limit is documented as a limit, not discovered by a failed boot.
- **Kernel mappings are shared, not copied.** Today the private level-2 copy
  hides later kernel mappings. The target is a single shared kernel PDPT plus a
  per-space window PDPT, which is also what makes the syscall window cheap to
  switch.
- **Switching is explicit**: `vmm.activate(space)` writes CR3 and records it in
  the per-CPU state. No implicit switch inside an allocation function.

### 2.3 Regions

A region is a contiguous virtual range with a policy attached:

```zig
pub const RegionKind = enum { anonymous, file, device, stack, guard, shared };

pub const Region = struct {
    base: u64, len: u64,
    kind: RegionKind,
    prot: Protection,        // read, write, execute, user
    state: enum { unmapped, lazy, resident },
    backing: union(RegionKind) { none: void, file: FileRef, phys: PhysRange },
    // accounting: pages_resident, pages_total
};
```

Regions are what make the following possible without ad-hoc code:

| Feature | How regions enable it |
|---|---|
| Demand paging | `lazy` region + fault handler that allocates and maps one page |
| File mapping | `file` region; fault reads the page through the file interface |
| Guard pages | a 0-len `guard` region, or absence of a region, with a distinct fault reason |
| Stack growth | `stack` region with a growable bound and a fault handler that extends by one page |
| Teardown | walk the list, unmap, free, drop references |
| Accounting | sum of resident pages per space, reported per process |

### 2.4 Page fault

The fault handler is a policy function over regions, in this order:

1. Address not in any region → `SIGSEGV`-equivalent, terminate the process,
   record the fault (address, rip, region snapshot).
2. In a `lazy` region → allocate, zero, map, resume.
3. In a `file` region, page in cache → map, resume; cache miss → read, insert,
   map, resume.
4. Write to a read-only page → verify permission, then fail or COW (COW is a later
   stage; until then this is a clean failure).
5. Kernel address faulted in kernel mode → panic with the crash record.
6. Fault in an interrupt handler → panic; handlers never fault on user memory.

The handler must be re-entrancy safe: a fault during page-in must not recurse
infinitely, so the fault path records "already resolving this address" and fails
on the second attempt.

### 2.5 Kernel heap

- Keep the arena allocator; add a **lock** (a spinlock is enough: allocations are
  short and never block).
- Add failure accounting: `allocations`, `frees`, `high_water`, `failed`.
- Add a debug-only guard region around each allocation and a fill pattern, so a
  buffer overflow in the kernel is caught at the next free rather than at an
  unrelated crash.
- Do **not** add a general-purpose allocator with size classes, per-CPU caches or
  compaction now. The workload does not justify it and the complexity would be
  paid for in every audit.

### 2.6 DMA

- One window today; the target keeps the idea and adds a **user for it**: bus
  addresses returned by the DMA interface are the only addresses a driver passes
  to hardware.
- `dma.release` stays as the single place that frees a mapped frame after an
  unmap — but once §2.2 lands, it stops being a special case.
- IOMMU: **translation is not in this initiative**, and no isolation is claimed.
  Stage K8 parses `DMAR`/`IVRS` and reports their presence; the DMA interface is
  written so that a later "translate" step can be inserted without changing
  drivers. That is a forward-compatible seam, not a feature.

## 3. Invariants (the tests are written against these)

| # | Invariant | Checked by |
|---|---|---|
| M1 | Every frame is either free, owned by exactly one region, or pinned | allocator accounting test |
| M2 | Destroying an address space returns its frame count to the pre-creation value | unit + integration |
| M3 | A mapped user page is never writable from the kernel window by accident | protect test |
| M4 | No TLB entry survives an unmap on any CPU that ran the space | shootdown test (needs K3) |
| M5 | A region list is consistent after any single failed operation | fault-injection unit test |
| M6 | Kernel heap bytes returned equal bytes requested (no silent leak) | accounting test |
| M7 | A fault on an unmapped address terminates the faulting task and no other | isolation test |
| M8 | No kernel address is reachable with user privilege | page-table audit test |

## 4. Concurrency and TLB

- **Per-space lock** protects the region list and the page tables of that space.
  Kernel-global mappings are modified only under the global VMM lock, at init.
- **TLB invalidation**: `invlpg` locally; a shootdown IPI for remote CPUs. The
  shootdown is required before stage K2 is declared complete, because otherwise
  M4 is false by construction on any SMP build.
- **No allocation while holding the space lock** if the allocation can fault.
  The region list nodes come from a dedicated small pool to keep the lock
  ordering simple.

## 5. Accounting and diagnostics

Per space: virtual size, resident pages, shared pages, page-table pages.
Global: free/used frames, heap high-water, fault counts by reason, shootdowns
sent, pages reclaimed.

These counters are the measurement basis for "measure before optimising" and for
the hardware-validation stage: a boot that reports a resident-page count for a
process, and the same count after exit returning to the baseline, is evidence.

## 6. What is deliberately out of scope

- NUMA awareness, page migration, huge pages beyond 2 MiB, memory hotplug.
- A swap device. There is no persistent swap contract and no device to back it.
- A slab allocator with per-CPU caches. Small objects matter later; the arena is
  sufficient for the kernel's own structures today.

Each of these is a stage entry, not a feature request: they require a contract
first (a measurable need plus a test that fails without them).
