# Kynox native SDK

Public interface for native Kynox applications. The SDK is the only supported
boundary between a user program and the kernel: applications must not import
kernel modules.

- Target: `x86_64-freestanding`, Zig **0.17.0**.
- ABI reference: [`docs/specs/syscall-abi.md`](../docs/specs/syscall-abi.md),
  revision **1**.
- Contract source: [`shared/syscall_abi.zig`](../shared/syscall_abi.zig). The
  kernel and this SDK alias it instead of keeping private copies, and
  `abi-conformance-tests` (in `zig build test`) fails when the contract, the
  kernel dispatch, the SDK or the specification diverge.
- Status: **in progress**. The revision is enforced at build/test time, not
  negotiated at runtime, and the door has never executed in a VM. Expect
  additive changes; numbers are never reused or renumbered.

## Layout

| File | Responsibility |
|---|---|
| `src/syscall.zig` | raw ABI: re-exports the shared contract (`contract`/`abi`), error catalog, result decoding. No policy. |
| `src/root.zig` | typed wrappers: console, process, IPC, capabilities, filesystem, display, input |
| `src/../shared/display.zig`, `input.zig`, `compositor.zig` | wire structures shared with the kernel |

## Entry contract

A native program is entered by the kernel as:

```zig
export fn kynox_user_main(window_base: u64, role: u64) noreturn
```

`window_base` is the base of the process's user window (code at `+0x0`, data at
`+0x1000`, two stack pages at `+0x4000`; see `shared/usermode.zig`). `role` is
the launch role assigned by the kernel. The program must never assume a fixed
base address.

## Usage

```zig
const sdk = @import("kynox_sdk");

// Console output (descriptor 1).
_ = sdk.write("hello from user mode\n");

// A call that proves the user→kernel→user transition.
if (sdk.syscall.knownError(sdk.ping())) |err| return err; // any coded error

// Filesystem: open/read/close are validated against the caller's address space.
const fd = sdk.fsOpen("/apps/hello.txt", 0);
if (sdk.syscall.knownError(fd) == null) {
    var buffer: [64]u8 = undefined;
    const read = sdk.fsRead(fd, &buffer);
    _ = sdk.fsClose(fd);
    _ = read;
}
```

Errors are returned as bit patterns: a negative value is `-(error code)`. Use
`sdk.syscall.knownError(status)`, `isError(status)` and `errorCode(status)` to
decode them; the catalog is `sdk.syscall.Error`.

The SDK does **not** provide an allocator, a libc, POSIX, dynamic process
creation, service discovery, dynamic linking or a threading API. Programs are
statically linked into the boot image by `build.zig` and written to the RamFS
by the kernel.

## Syscalls exposed

22 numbers, `1–11` and `13–23`; number 12 is reserved. The full argument and
result contract, plus the validation rules and the error table, are in
[`docs/specs/syscall-abi.md`](../docs/specs/syscall-abi.md). Do not add a number
to the SDK without adding it to that document.

## Validation state

Executed on 2026-10-31 with Zig 0.17.0 (host):

| Command | Result |
|---|---|
| `zig build` | success — bootloader, kernel, both native applications and the EFI image |
| `zig build test` | success — 615/615 tests, including `sdk-tests` (4) |

Not executed: `zig build qemu-test`, `zig build qemu-storage-test`,
`zig build qemu-interactive-test` (no QEMU/OVMF in that environment). The SDK
wrappers therefore compile and their pure logic is tested, but the runtime path
inside QEMU is unverified for this snapshot.

## Guidelines for contributors

- Keep `src/syscall.zig` free of policy: it encodes the ABI, nothing else.
- Every wrapper must propagate the raw status; do not translate errors into
  abstract ones that lose the code.
- New wire structures belong in `shared/` and need a `wire_size`, a version
  field and bounds checks in the kernel.
- Update `docs/specs/syscall-abi.md`, `CHANGELOG.md` and the status inventory in
  the same change that adds or changes a call.
