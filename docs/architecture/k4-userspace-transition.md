# K4 — Userspace Transition Design

Status: **planning**; references `execution-model.md`, `memory-management.md`, `security-architecture.md`, `syscall_abi.zig`.

## 1. Ring 3 transition

### Entry point

- `syscall.s`: saves user registers (`PUSH_REGISTERS`), pushes error code (0 for syscall), calls `syscall_handler` in Zig (`interrupt.zig` stub convention).
- Handler validates pointer arguments using `isUserRange` (exists in `paging.zig` / `memory-management.md`).
- No user-mode pointer is trusted: the kernel resolves the pointer to a physical address via page tables or validates the range.
- After handler, registers restored (`POP_REGISTERS`); `iretq` returns to user `CS`/`SS`/`RIP`/`RFLAGS`/`RSP` (from `context.zig`: `rsp`, `rip`, `rflags`, `cs`, `ss` saved at offsets 128, 144, 136, 152, 160).

### Stack setup

- User stack (`user_stack`) must have guard page below (lower address) and alignment of 16 bytes (System V AMD64 ABI).
- Kernel stack (`kernel_rsp`, set in `Task`) is separate; used for interrupt/syscall handlers.
- The switch (`task.s`) builds the frame on the kernel stack (`kynnox_kernel_stack_pointer` + `subq $176, %rsp`) and uses `popq` to restore user registers before `iretq`.

### W^X

- `paged.zig` (or `paging.zig`) enforces W^X: executable pages (`PF_X`) must not be writable; writable pages must not be executable.
- The `ELFLoader` (K4.6) must verify segment flags (`p_flags`) and reject any segment that violates W^X.
- The `KEXLoader` (K4.7) must apply the same validation to payload segments.

## 2. User memory validation and safe copy

### Interface

```zig
pub fn validateUserRange(addr: u64, len: usize) bool;
pub fn copyFromUser(dst: [*]u8, src: u64, len: usize) !void;
pub fn copyToUser(dst: u64, src: [*]const u8, len: usize) !void;
```

### Invariants

1. `validateUserRange` must resolve to page table entry; if page not mapped or not in user range, return false.
2. `copyFromUser` must not access `src` directly; must copy through validated page mapping (or use `copyFromUser` implementation that validates once, then copies without re-checking to avoid TOCTOU).
3. `len` must not overflow `base + len`; overflow check required.
4. The copy must not cross page boundaries that change permissions (if `len` spans pages with different permissions, each page must be validated separately; simplest: validate full range, then copy with verified pointer).

### No TOCTOU

- The pointer `src` is validated; after validation, the pointer is not changed by user code (it is a copy of the validated address, not a pointer that user can modify).
- The copy is performed in kernel mode with interrupts disabled only if required by critical section; long copies should not disable interrupts (per AGENTS.md 4.4: avoid blocking with spinlock; do not disable interrupts for long).

## 3. Entry point and arguments

- `ELFLoader` reads `e_entry`; initial thread `rip` = `e_entry`.
- Arguments passed through registers per System V AMD64 ABI: `rdi` = argc, `rsi` = argv pointer.
- `argv` is a pointer to array of pointer to string; the kernel must validate `argv` array and all string pointers before copying.
- Environment (`envp`) optional for initial scope; can be passed as null.

## 4. Argument and environment validation

- All user pointers in syscall arguments must be validated before dereference.
- The syscall ABI (`syscall_abi.zig`) specifies pointer types; the kernel must enforce these.
- No pointer validation failure must cause kernel panic; only process termination (set `.exiting`).

## 5. ABI compatibility

- System V AMD64 ABI used for user-mode calls; kernel uses different convention (`syscall` instruction, not `call`).
- Red zone (128 bytes below `rsp`) is not used by kernel handlers; user-mode code may use it, but the kernel must not assume it exists when saving context (already handled by `PUSH_REGISTERS` which saves all registers including those that might be in red zone).
- Stack alignment: `rsp` must be multiple of 16 before `syscall` instruction; if not, `ALIGN_STACK` macro pushes padding.
