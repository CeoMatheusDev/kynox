# Kynox native syscall ABI (KX-ABI)

> Normative description of the syscall interface between user mode and the
> Kynox kernel.
>
> **Source of truth:** [`shared/syscall_abi.zig`](../../shared/syscall_abi.zig).
> The kernel (`kernel/arch/x86_64/syscall.zig`) and the SDK
> (`sdk/src/syscall.zig`) import that module; neither keeps a private copy.
> This document is normative **for the meaning** of the calls and is kept in
> agreement with the module by `abi_conformance.zig`, which fails
> `zig build test` when the table, the dispatch, the SDK or this file diverge.
>
> Revision **1** — status: implemented, integrated in the boot path, validated
> on the host only (no QEMU run yet; see `docs/audits/2026-10-31-audit.md`).

## 0. Three different versions

| Version | Where | Changes when |
|---|---|---|
| System version | `version.zig` | a product release happens (`0.1.0-alpha.1`) |
| **ABI revision** | `shared/syscall_abi.zig` → `version` | the **meaning** of the contract changes |
| Format versions | handoff v1, KEX v1, KPK, KNV headers | that specific format changes |

Adding a new call number does **not** require a new ABI revision. Renumbering,
removing, or changing the argument/result semantics of an existing call does.

### History of the revision number

The previous tree carried three informal labels — 9 (SDK README), 12 (error
catalog comment), 13 (SDK constant) — that disagreed with each other and were
never enforced by the kernel (audit finding A-04). Revision 1 is the first
contract issued from a single source. It is **wire compatible** with that tree:
no number was renumbered, removed or repurposed, 12 stays reserved, and every
error code keeps its value.

## 1. Calling convention

| Item | Contract |
|---|---|
| Instruction | `syscall` (`IA32_EFER.SCE` set; kernel programs `STAR`, `LSTAR`, `SFMASK`) |
| Number | `RAX` |
| Arguments | `RDI`, `RSI`, `RDX`, `R8` (the fourth travels in `R8` because `syscall` overwrites `RCX`) |
| Primary result | `RAX` |
| Secondary result | `RDX` (the `receive*` family returns the message value there) |
| Clobbered by the instruction | `RCX` (return address), `R11` (flags); both are restored before returning to user mode |
| Errors | negative `RAX`, `RAX == -(error code)` |
| Privilege identifiers | `Privilege.kernel = 0`, `Privilege.user = 3` (the value is the CPL the entry stub passes in `RSI`) |
| Stack | the entry switches to the kernel stack of the task; the user stack pointer is saved and restored |

The kernel does not use `syscall` for its own calls: it invokes
`kynox_syscall_handler` directly with `privilege = Privilege.kernel`. Calls
that need a user process refuse a kernel caller with `not_allowed` or
`not_authorized`.

## 2. Frame layout

The entry stub builds a frame with the same shape as the interrupt frames so
the scheduler can switch away from a task that blocks inside a call:

| Offset | Field |
|---:|---|
| 0 | `r15`, 8 `r14`, 16 `r13`, 24 `r12`, 32 `r11`, 40 `r10`, 48 `r9`, 56 `r8`, 64 `rbx`, 72 `rbp` |
| 80 | `rdi` (arg 1) |
| 88 | `rsi` (arg 2) |
| 96 | `rdx` (arg 3) |
| 104 | `rcx` (user return address) |
| 112 | `rax` (number in, result out) |

Sequence: save user `RSP` → load the per-task kernel stack → push the `iretq`
frame (`SS = 0x23`, user `RSP`, user flags, `CS = 0x1b`, `RCX`) → push the
two-shape marker (`error code = 0`, `vector = 0`) → save the general registers
→ call the handler → restore → `iretq`. Blocking calls set
`kynox_syscall_blocked` so the scheduler can run another task; the result is
written directly into the saved frame when the wait completes.

## 3. Syscall table

Numbers in use: **1–11, 13–23**. Number **12 is reserved** and must never gain
a different meaning.

| # | Name | Arguments (`RDI`, `RSI`, `RDX`, `R8`) | Result |
|---:|---|---|---|
| 1 | `ping` | — | `0x42` (`ping_result`) |
| 2 | `write` | buffer, length, descriptor | bytes written |
| 3 | `memcpy` | destination, source, length | bytes copied |
| 4 | `exit` | code | — (task ends) |
| 5 | `send` | channel, side, kind, value | 0 on success |
| 6 | `receive` | channel, side | kind; value in `RDX` |
| 7 | `copy_to` | process, destination, source, length | bytes copied |
| 8 | `receive_blocking` | channel, side | kind; value in `RDX` |
| 9 | `grant` | process, kind, subject, rights | 0 on success |
| 10 | `revoke` | process, kind, subject | 0 on success |
| 11 | `receive_timeout` | channel, side, ticks | kind; value in `RDX` |
| 12 | — | — | **reserved** |
| 13 | `fs_open` | path address, path length, flags | descriptor |
| 14 | `fs_close` | descriptor | 0 |
| 15 | `fs_read` | descriptor, buffer, length | bytes read |
| 16 | `fs_write` | descriptor, buffer, length | bytes written |
| 17 | `fs_create` | path address, path length | descriptor (mode 0644) |
| 18 | `fs_mkdir` | path address, path length | 0 |
| 19 | `display_info` | address, length | bytes written |
| 20 | `present` | request address, length | 0 |
| 21 | `input_poll` | event address, length | 1 event / 0 none |
| 22 | `fs_truncate` | descriptor, new size | 0 |
| 23 | `input_wait` | event address, length, timeout ticks | 1 event |

### Notes per family

- **Console** (`write`): `descriptor` must be `1` (`Descriptor.console`); the
  buffer must be mapped readable; length ≤ 64 KiB.
- **Memory** (`memcpy`, `copy_to`): both ranges are validated; overlap is
  handled (`memmove` semantics); `copy_to` validates the destination inside the
  target address space and the source in the caller's.
- **IPC** (`send`/`receive*`): requires the channel capability with `send` or
  `receive`. `receive_timeout` with `ticks = 0` means "no deadline" and behaves
  like `receive_blocking`; on expiry the wait is removed and the message stays
  queued.
- **Capabilities** (`grant`/`revoke`): the caller must hold the capability with
  `delegate`; granted rights must be a subset of the caller's rights.
- **Filesystem** (`fs_*`): paths are UTF-8, **not** NUL terminated, at most 255
  bytes; they are copied into a kernel buffer **after** the range check.
- **Display** (`display_info`, `present`): the framebuffer address is never
  exposed; `present` requires the display capability with `write`.
- **Input** (`input_poll`, `input_wait`): requires the input capability with
  `read`; `no_input` when the kernel has no queue.

## 3.1 Capability arguments

`grant` (`RSI` = kind, `R8` = rights) and `revoke` (`RSI` = kind) take values
from the capability part of the contract (`shared/syscall_abi.zig`); the kernel
maps them to its internal kind and the SDK exposes them as
`sdk.CapabilityKind` / `sdk.Right`.

| Kind | Value | Subject named by the call |
|---|---:|---|
| `channel` | 0 | channel identifier |
| `process` | 1 | process identifier (`copy_to` destination) |
| `display` | 2 | 0 (the display is unique) |
| `input` | 3 | 0 (the input queue is unique) |

| Right | Value | Allows |
|---|---:|---|
| `send` | 1 | put a message in the subject |
| `receive` | 2 | take a message from the subject |
| `delegate` | 4 | give the capability to another process |
| `write` | 8 | write into the address space the capability names |
| `read` | 16 | take an input event |
| `all` | 31 | every right |
| `use` | 3 | use the subject without giving it away |

A granted set must be a subset of the caller's rights; `delegate` is not
implied unless requested explicitly.

## 4. Validation applied by the kernel

In this order, before any dereference:

1. Length constraints (`length != 0`, `length <= max_block_length`, or at least
   the wire size of the structure) → `invalid_length`.
2. Whole range mapped in the caller's space with the required permission
   (`paging.isUserRange` / `isUserRangeIn`, page by page, overflow safe) →
   `invalid_address`.
3. Capability/right checks → `not_authorized`.
4. Descriptor namespace of the process → `bad_descriptor`.

User pointers are never dereferenced before step 2, and no kernel pointer is
ever exposed to user mode.

## 5. Error codes

```text
RAX >= 0 : success value (for receive*: the message kind)
RAX <  0 : error, RAX == -(code)
```

| Code | Name | Meaning |
|---:|---|---|
| 1 | `unknown_call` | number not dispatched |
| 2 | `invalid_address` | address/length is not a valid user range |
| 3 | `invalid_length` | zero, too large, or shorter than the required structure |
| 4 | `not_allowed` | not permitted for this privilege level or descriptor |
| 5 | `empty_queue` | nothing to receive |
| 6 | `unknown_channel` | channel does not exist |
| 7 | `full_queue` | receiver queue is full |
| 8 | `unknown_process` | process does not exist |
| 9 | `wait_impossible` | the wait would be a busy loop |
| 10 | `not_authorized` | missing capability/right, or no process context |
| 11 | `unknown_kind` | capability kind does not exist |
| 12 | `invalid_rights` | empty or inapplicable rights |
| 13 | `timeout` | deadline expired first |
| 14 | `no_such_file` | path does not resolve |
| 15 | `no_space` | no free block or inode |
| 16 | `bad_descriptor` | descriptor is not open |
| 17 | `too_many_open_files` | per-process table full |
| 18 | `name_exists` | path already exists |
| 19 | `invalid_name` | malformed path/name |
| 20 | `file_too_large` | exceeds the filesystem limit |
| 21 | `io_error` | filesystem refused for another reason |
| 22 | `no_display` | no usable display |
| 23 | `invalid_geometry` | rectangle empty or outside the display |
| 24 | `invalid_format` | pixel format unsupported |
| 25 | `no_input` | no user input queue |

New codes are appended; existing values are never renumbered.

## 6. Conformance

| Check | Where | Runs |
|---|---|---|
| Every published number is dispatched by the kernel switch | `abi_conformance.zig` | `zig build test` |
| No number is dispatched that the table does not publish | `abi_conformance.zig` | `zig build test` |
| Every table row exists in this document, and the revision is stated | `abi_conformance.zig` | `zig build test` |
| Reserved number 12 remains unassigned and documented | `abi_conformance.zig` | `zig build test` |
| SDK numbers/limits are the contract's (no private copy) | `sdk/src/syscall.zig` tests | `zig build test` |
| SDK error enum equals the contract constants, field by field | `sdk/src/syscall.zig` tests | `zig build test` |
| Privilege identifiers match the entry stub | `shared/syscall_abi.zig` tests | `zig build test` |
| A user-mode `ping` round trip | kernel self test + boot script | QEMU (`qemu-test`) — **not executed in this snapshot** |

The last row is the only runtime check of the ABI and it requires QEMU; see
`docs/BUILD.md` for the procedure and `docs/releases/0.1.0-alpha.1.md` for the
gate.

## 7. Changing the ABI

1. Edit `shared/syscall_abi.zig` (number, limit, error code).
2. Handle the number in `kernel/arch/x86_64/syscall.zig` and/or add the SDK
   wrapper in `sdk/src/root.zig`.
3. Update this document (table row, family note, §6 if needed).
4. Run `zig build test` — the conformance test fails until 1–3 agree.
5. Add an entry to `CHANGELOG.md`. Bump `version` in the contract only if the
   meaning of an existing call changed.
