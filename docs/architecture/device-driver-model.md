# Device and driver model

- Status: **planning document**: the target model, the current state, and the
  stages that get from one to the other. It does not describe implemented code.
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md) §4.11–4.13,
  [`execution-model.md`](execution-model.md),
  [`kernel-internals.md`](kernel-internals.md),
  [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md) stages K7–K9,
  ADR-[0002](../decisions/0002-single-virtio-transport.md),
  ADR-[0003](../decisions/0003-legacy-virtio-blk-stub.md).

## 1. Current state, precisely

| Piece | Reality |
|---|---|
| Enumeration | `arch/x86_64/pci.zig`: configuration space through port `0xCF8/0xCFC`, BAR decoding, capability walking. Host-tested (36 tests). No ECAM/MMCONFIG, no PCIe hierarchy beyond bus 0–255 scan |
| Driver registration | **there is no driver model.** A driver is a function that `main.zig` calls |
| Lifecycle | probe → initialise, in call order, inside `kmain`. Success is recorded; failure halts |
| Resources | drivers read their own BARs; nothing arbitrates address, IRQ or DMA allocation |
| Interrupts | **no registration API.** Vectors 32/33 are PS/2 keyboard and PIT; 34–47 are acknowledged and ignored. MSI capability is detected but not programmed |
| Containment | KVDI has a real containment model (quarantine after repeated faults, fault injection harness, 173 tests). VirtIO has none |
| VirtIO | one modern transport used by blk and net; a **second, legacy transport** exists as duplication (`virtio.zig`, `virtio_blk.zig`) with 15 tests; `virtio-net` transmits nothing while returning success |
| Input | PS/2 keyboard via IRQ 1 and polling; no mouse driver; no input device abstraction beyond the KVDI window model |
| Framebuffer | direct writes from the kernel with a benchmark |
| Serial | output only |
| ACPI | table parsing (host-tested) and MADT discovery; no AML interpreter, so no `_PRT`, no `_S5`, no power management |

The consequence: adding a second device class today means editing `main.zig` and
finding a free vector. That is the problem the model solves.

## 2. The model

Three nouns, each a struct with a clear owner:

### 2.1 Device

The hardware as discovered: a vendor/product id, a location (segment/bus/device/
function, or an ACPI description), a set of resources (MMIO ranges, I/O ports,
interrupt lines, DMA constraints), and a state
(`discovered → claimed → running → degraded → quarantined`).

### 2.2 Driver

A static descriptor, registered at compile time:

```zig
pub const Driver = struct {
    name: []const u8,
    matches: []const Match,          // vendor/device pairs or a class code predicate
    probe: *const fn (dev: *Device, res: *const Resources) ProbeError!void,
    start: *const fn () StartError!void,
    stop: *const fn () void,
    suspend: ?*const fn () void,
    resume: ?*const fn () void,
    detach: *const fn () void,
};
```

Rules:

1. **A driver never searches the bus.** The device layer enumerates, matches and
   passes the device plus its resources.
2. **A driver never picks a vector.** It registers a handler for a resource and
   the interrupt layer returns an opaque handle.
3. **A driver never allocates physical addresses directly**; it asks the DMA
   interface.
4. **Probe may fail without stopping the system.** Failure moves the device to
   `degraded` with a reason and the boot continues.
5. **A driver has a teardown path** that is called even if start failed, so
   partial initialisation cannot leak.

### 2.3 Resource

A typed grant: MMIO range, I/O port range, interrupt line or message, DMA window.
Resources are exclusive by default, and the allocator refuses a double claim
(that refusal is the point). Shared granting exists for lines like the legacy
cascade and is explicit.

## 3. Interrupt registration

```zig
pub const IrqHandle = struct { vector: u8, slot: u8 };

pub fn register(line: Line, handler: *const fn (ctx: *anyopaque) void, ctx: *anyopaque) !IrqHandle;
pub fn acknowledge(handle: IrqHandle) void;
pub fn unregister(handle: IrqHandle) void;
```

- **Lines are abstract.** A legacy line (IOAPIC redirection entry) and an MSI
  vector both resolve to a `Line`, and the interrupt layer owns the mapping.
- **Message interrupts**: an MSI-capable function gets a vector from a per-CPU
  pool, the capability is programmed in the device layer, and the destructor
  returns the vector. The audit found the capability parsed but never used; this
  is the API that uses it.
- **The handler runs with interrupts masked on that CPU for its line**, in the
  minimum context, and must return promptly (no allocation, no blocking).
- **Spurious and unhandled interrupts are counted**, not silently acknowledged.
  The current code acknowledges 34–47 and forgets; that masks real faults.

## 4. DMA

- One interface: `dma.allocate(len, constraints) → { bus_addr, vaddr, phys }`,
  `dma.free(handle)`.
- Constraints: alignment, maximum physical address (32-bit-only devices), and
  contiguity. Today the window is 64 MiB identity-mapped, which satisfies all
  three by construction; the interface stays because the implementation must be
  replaceable by an IOMMU-backed one.
- Buffers handed to hardware are **owned by the driver until completion**, and
  freeing before completion is a detectible error in debug builds.

## 5. Class interfaces

Each device class has one interface, defined by its consumer, not by the driver:

| Class | Interface | Consumers |
|---|---|---|
| Block | `read(offset, buf)`, `write`, `flush`, `capacity`, `block_size` | storage layer, filesystems |
| Network | `transmit(frame)`, `receive(callback)`, `mtu`, `mac`, `link_state` | network stack (future) |
| Input | `event stream` of key/button/motion records | console, pointer, compositor |
| Display | framebuffer description + present | display core |
| Serial/console | `write`, `read` (polled or IRQ) | logging, diagnostics |

Rule: **a class interface is satisfied by at least one real driver before it
gets a second consumer.** No speculative abstractions.

## 6. Failure and containment

| Failure | Response |
|---|---|
| Probe fails | device marked `degraded`, reason logged, boot continues |
| Repeated I/O timeout | driver requests quarantine; class interface returns `Quarantined` |
| Quarantined device | stopped, resources retained, no new requests, an operator command could retry (later) |
| Driver crashes the kernel | crash record includes the driver name; the boundary between "kernel bug" and "driver bug" must be visible |
| Hot unplug | not supported in this initiative; a `detach` path exists, tested only by simulated removal in KVDI |

The KVDI containment model is the reference implementation of this table; the
target is that every driver class can express the same states.

## 7. Device discovery sources

1. **PCI** (port I/O today; ECAM later, and only if a measurement shows the
   config-space access cost matters — it is a boot-time cost, so "later" is
   probably "never").
2. **ACPI**: MADT for interrupt controllers, and (later, with an AML interpreter)
   `_PRT` for route tables and `_S5` for power.
3. **Platform/fixed devices** described by the boot handoff: the framebuffer, the
   serial port, the ACPI RSDP.
4. **Virtual buses** (KVDI) which are a containment wrapper around a transport,
   not a bus.

## 8. What the driver model must not become

- **Not a plugin system.** Drivers are compiled in; there is no loading, no
  versioned binary interface, no symbol resolution. The source tree is the
  interface.
- **Not an object-oriented hierarchy.** No base class, no virtual inheritance;
  one struct per class interface, satisfied structurally.
- **Not a hot-plug framework** until there is a device that can be unplugged in a
  test.

## 9. Tests per driver (the tier that a driver must reach)

| Tier | Evidence |
|---|---|
| Unit (host) | pure protocol code: descriptor rings, capability parsing, command encoding; a fake device backs the register file |
| Integration (QEMU) | the driver probes, initialises, and completes one request; the block driver reads a known sector, the net driver transmits a frame the peer receives |
| Fault injection | the transport returns errors at each step; the driver reports, quarantines, and does not corrupt state |
| Stress | 10 000 requests, no descriptor leak, no timeout, counters balanced |
| Hardware | the same driver on a real device of the class (a USB-less SATA/NVMe device or a PCIe NIC), documented per device |

A driver is **VALIDATED** only after the hardware tier for that device, per the
project's existing classification rules.
