# Kynox native syscall ABI (KX-ABI)

> Normative description of the syscall interface between user mode and the
> Kynox kernel.
>
> Written from [`kernel/arch/x86_64/syscall.zig`](../../kernel/arch/x86_64/syscall.zig),
> [`kernel/arch/x86_64/syscall.s`](../../kernel/arch/x86_64/syscall.s) and
> [`sdk/src/syscall.zig`](../../sdk/src/syscall.zig) on 2026-10-31. The code is
> the source of truth; if this document disagrees with it, the document is a bug.

## 0. Status

- **Implemented and integrated:** the kernel entry path, the dispatch table and
  the SDK wrappers exist and are exercised by the native applications embedded
  in the boot image (`user/hello.zig`, `user/client.zig`) and by `zig build test`
  for the pure parts.
- **Not verified end to end in this repository snapshot:** the runtime behavior
  requires a QEMU boot, which has not been executed here
  (`docs/audits/2026-10-31-audit.md`, A-02).
- **ABI revision is currently ambiguous** — the SDK declares revision 13, the
  error catalog claims 12, the previous SDK README claimed 9, and the kernel
  declares no version at all (audit A-04). The value in §7 is the SDK's claim,
  not an enforced contract. Until the kernel exposes and enforces it, treat the
  ABI as **unstable** and expect numbers to be added; existing numbers must not
  be renumbered.

## 1. Calling convention

| Item | Contract |
|---|---|
| Instruction | `syscall` (`IA32_EFER.SCE` must be set; the kernel installs `IA32_STAR`, `IA32_LSTAR`, `IA32_SFMASK`) |
| Number | `RAX` |
| Arguments | `RDI`, `RSI`, `RDX`, `R8` (a fourth argument travels in `R8` because the instruction overwrites `RCX`) |
| Primary result | `RAX` |
| Secondary result | `RDX` (used by the receive family to return the message value) |
| Clobbered by the instruction | `RCX` (return address) and `R11` (flags); both are restored before returning to user mode |
| Errors | two's-complement negative value in `RAX` (`-1` … `-25`, see §6); a non-negative result is a success value |
| Preserved | every other general-purpose register, as observed by the caller |
| Stack | the entry point switches to the kernel stack of the running task; the user stack pointer is saved and restored. The handler never runs on a user stack. |
| Interrupts | masked by `IA32_SFMASK` (`flag_mask = 0x7FD`) during entry; the caller's flags are restored by `iretq` |

The kernel does **not** use the `syscall` instruction for its own calls: the
handler is invoked directly with `privilege = kernel`, and only the entry stub
reaches user mode. Some calls therefore refuse kernel callers
(`error.not_allowed`).

### 1.1 Frame built by the entry point

The entry stub builds a frame with the same shape as the interrupt frames, so
the scheduler can switch away from a task blocked in a syscall. Offsets are
those of `SyscallFrame`/`interrupt.Frame`:

| Offset | Field |
|---:|---|
| 0 | `r15`, 8 `r14`, 16 `r13`, 24 `r12`, 32 `r11`, 40 `r10`, 48 `r9`, 56 `r8`, 64 `rbx`, 72 `rbp` |
| 80 | `rdi` (arg 1) |
| 88 | `rsi` (arg 2) |
| 96 | `rdx` (arg 3) |
| 104 | `rcx` (user return address) |
| 112 | `rax` (number in, result out) |

The handler signature is
`kynox_syscall_handler(frame: *SyscallFrame, privilege: u64)`; `privilege` is
the discriminator that separates a user call from a direct kernel call.

### 1.2 Path to user mode

`syscall` does not switch stacks. The stub saves `RSP` into
`kynox_user_stack_pointer`, loads the per-task kernel stack from
`kynox_kernel_stack_pointer`, pushes the `iretq` frame (`SS = 0x23`,
saved `RSP`, saved flags, `CS = 0x1b`, `RCX`), the two-shape marker
(`error code = 0`, `vector = 0`), and the general registers. The return is an
interrupt return, which restores the user segments and stack.

Blocking calls (`receive`, `receive_blocking`, `receive_timeout`,
`input_wait`) mark `kynox_syscall_blocked` so the scheduler can run another
task and later resume this one; the message is delivered directly into the
saved frame, so the task continues after the call as if it had returned
immediately.

## 2. Syscall table

Numbers in use: **1–11, 13–23**; **12 is reserved** and must not be reused for
a different purpose without a documented decision.

| # | Name | Arguments (`RDI`, `RSI`, `RDX`, `R8`) | Result | Notes |
|---:|---|---|---|---|
| 1 | `ping` | — | fixed non-zero value | proves user→kernel→user transition |
| 2 | `write` | buffer, length, descriptor | bytes written | `descriptor` must be `1` (console); length ≤ 64 KiB; buffer must be mapped readable |
| 3 | `memcpy` | destination, source, length | bytes copied | both ranges validated; overlap-safe (`memmove` semantics) |
| 4 | `exit` | code | — (task ends) | terminates the calling task |
| 5 | `send` | channel, side, kind, value | 0 on success | requires `send` right on the channel capability; `full_queue` when the queue is full |
| 6 | `receive` | channel, side | `RAX` = message kind, `RDX` = value | requires `receive` right; `empty_queue` when nothing is queued |
| 7 | `copy_to` | process, destination, source, length | bytes copied | cross-address-space copy; destination validated in the target space, source in the caller's |
| 8 | `receive_blocking` | channel, side | kind / value (`RDX`) | blocks the caller until a message arrives |
| 9 | `grant` | process, kind, subject, rights | 0 on success | caller must hold the capability **with** `delegate`; granted rights must be a subset |
| 10 | `revoke` | process, kind, subject | 0 on success | caller must hold `delegate` |
| 11 | `receive_timeout` | channel, side, ticks | kind / value (`RDX`) | `ticks = 0` means "no deadline" (same as blocking); expiry yields `timeout` and the message stays queued |
| 12 | — | — | — | **reserved** |
| 13 | `fs_open` | path address, path length, flags | descriptor | path ≤ 255 bytes, not NUL-terminated; requires the caller to be a known process |
| 14 | `fs_close` | descriptor | 0 | |
| 15 | `fs_read` | descriptor, buffer, length | bytes read | buffer must be writable in the caller's space |
| 16 | `fs_write` | descriptor, buffer, length | bytes written | buffer must be readable |
| 17 | `fs_create` | path address, path length | descriptor | created with mode `0644` |
| 18 | `fs_mkdir` | path address, path length | 0 | |
| 19 | `display_info` | address, length | bytes written | fills a `display.DisplayInfo`; length is both the capacity and the returned size |
| 20 | `present` | request address, length | 0 | requires the `display` capability with `write`; request is a `display.PresentRequest` validated before use |
| 21 | `input_poll` | event address, length | `1` event / `0` none | requires the `input` capability with `read`; `no_input` when no queue exists |
| 22 | `fs_truncate` | descriptor, new size | 0 | shrinks a regular file |
| 23 | `input_wait` | event address, length, timeout ticks | `1` event | requires `input`+`read`; `ticks = 0` waits without a deadline |

Filesystem and IPC calls require a valid caller process context; a call that
cannot resolve the caller fails with `not_authorized`.

## 3. Validation rules applied by the kernel

Every call that takes a user address applies, in this order:

1. `length != 0` and `length <= max_block_length` (65,536) where a length is
   meaningful → `invalid_length`.
2. The whole range is mapped in the caller's address space with the required
   permission (`paging.isUserRange(..., writable)`), page by page, with
   overflow-safe bounds → `invalid_address`.
3. Paths are copied through a 255-byte kernel buffer; the copy happens after
   the range check, never before.
4. Optional capability checks (`send`/`receive` rights, `display`/`input`
   kinds) → `not_authorized`.
5. Descriptor namespace is per process; an unknown descriptor → `bad_descriptor`.

The kernel never dereferences a user pointer directly: all access happens after
range validation, and copies into kernel buffers are bounded.

## 4. Address-space assumptions

- User code, data and stack live in a per-process window described by
  `shared/usermode.zig`: `code_offset = 0x0`, `data_offset = 0x1000`,
  `stack_offset = 0x4000`, `stack_pages = 2`, `window_size = 0x6000`.
- The window base is chosen by the kernel at process creation and is **not** a
  fixed address; user code never assumes an address.
- Kernel addresses are never valid for a syscall argument; a "user range" is a
  set of present user pages.

## 5. Error encoding

```c
/* RAX >= 0 : success value
   RAX <  0 : error, RAX == -(error code)          */
```

Calls that return a message kind (`receive*`) use the same rule: a negative
`RAX` is an error, a non-negative `RAX` is a message kind whose value is in
`RDX`.

## 6. Error codes

| Code | Name | Meaning |
|---:|---|---|
| 1 | `unknown_call` | number not implemented |
| 2 | `invalid_address` | address/length pair is not a valid user range |
| 3 | `invalid_length` | zero, too large, or shorter than the required structure |
| 4 | `not_allowed` | call not permitted for the caller's privilege level or descriptor |
| 5 | `empty_queue` | nothing to receive |
| 6 | `unknown_channel` | channel id does not exist |
| 7 | `full_queue` | receiver queue is full |
| 8 | `unknown_process` | process id does not exist |
| 9 | `wait_impossible` | the wait would be a busy loop (no other runnable task) |
| 10 | `not_authorized` | missing capability/right, or no process context |
| 11 | `unknown_kind` | capability kind does not exist |
| 12 | `invalid_rights` | empty or inapplicable rights set |
| 13 | `timeout` | deadline expired before the message arrived |
| 14 | `no_such_file` | path does not resolve |
| 15 | `no_space` | no free block or inode |
| 16 | `bad_descriptor` | descriptor is not open |
| 17 | `too_many_open_files` | per-process table is full |
| 18 | `name_exists` | path already exists |
| 19 | `invalid_name` | malformed path or name |
| 20 | `file_too_large` | exceeds filesystem limit |
| 21 | `io_error` | filesystem refused for any other reason |
| 22 | `no_display` | firmware provided no usable display |
| 23 | `invalid_geometry` | presentation rectangle is empty or outside the display |
| 24 | `invalid_format` | pixel format not supported |
| 25 | `no_input` | no user input queue available |

New codes are appended; existing values are never renumbered.

## 7. Versioning

| Artifact | Claim today | Required state |
|---|---|---|
| SDK constant | `abi_version = 13` (`sdk/src/syscall.zig`) | keep in sync with the kernel |
| Error catalog comment | "v12" | correct or remove |
| Kernel | no version constant | must expose the implemented ABI revision and reject/allow by policy |
| This document | revision 13 (as claimed by the SDK) | update together with the kernel constant |

Until the kernel-side constant exists, **no external code may depend on the ABI
revision**. Adding syscalls does not require a new revision; changing argument
or result semantics does, and must be recorded in `CHANGELOG.md`.
