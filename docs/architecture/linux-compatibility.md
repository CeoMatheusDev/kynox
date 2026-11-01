# KLC — Kynox Linux Compatibility layer

- Status: **planning document**. Nothing here is implemented; KLC is 0%.
  Kynox does **not** run Linux binaries today and makes no compatibility claim.
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md) §4.5–4.10,
  [`application-ecosystem.md`](application-ecosystem.md) §8,
  [`graphics-compatibility.md`](graphics-compatibility.md) §8,
  [`security-architecture.md`](security-architecture.md) §8,
  [`windows-compatibility.md`](windows-compatibility.md),
  ADR-[0010](../decisions/0010-compatibility-execution-model.md),
  [`../roadmap/COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md).

## 1. What KLC is, and what it is not

KLC runs **unmodified Linux x86-64 ELF executables** on the Kynox kernel by
implementing the contracts those binaries depend on, using Kynox mechanisms.

It is not a Linux kernel, not a virtual machine, not a container of a Linux
userland, and not a port of glibc or musl. There is no Linux kernel underneath,
no `ld.so` from another project, and no foreign libc. Kynox does not ship Linux;
it implements the interfaces an application observes.

The honest scope statement, to be repeated in every release note until the
matrix proves otherwise:

> KLC is an incremental matrix of formats, syscalls, libraries and behaviours,
> each with tests. "Runs Linux software" is not a claim this project makes.

## 2. The seven things that must be separated

The most common mistake in this area is treating "Linux compatibility" as one
problem. Kynox separates it into seven contracts that fail independently:

| # | Contract | Example failure if conflated |
|---|---|---|
| 1 | **Executable format** | loading an ELF proves nothing about its syscalls |
| 2 | **Calling convention (psABI)** | a binary can be loaded and crash on the first call `[S21]` |
| 3 | **Syscall interface** | a correct call crashes if the ABI number differs |
| 4 | **Library ABI** | a program links but its `malloc` semantics differ |
| 5 | **User-space behaviour** | signals, `/proc`, permissions differ subtly |
| 6 | **System services** | fonts, DNS, audio, session integration are absent |
| 7 | **Graphics** | a window cannot be created without a window system |

Each contract has its own support matrix, its own tests and its own maturity
level. A program is "supported" only when every contract it touches is
supported, and the matrix names which ones are.

## 3. Executable format: ELF64

### 3.1 What the loader must parse

| Structure | Use | Validation |
|---|---|---|
| `Elf64_Ehdr` | class, data, machine, entry, program-header offset | magic, class=ELF64, data=LSB, machine=x86-64, bounds |
| `Elf64_Phdr[]` | `PT_LOAD`, `PT_DYNAMIC`, `PT_INTERP`, `PT_TLS`, `PT_GNU_STACK`, `PT_GNU_RELRO`, `PT_NOTE` | offsets, sizes, alignment, non-overlap, no writes to text after load |
| `PT_LOAD` | segment mapping | page alignment, `p_memsz ≥ p_filesz`, W^X split |
| `PT_TLS` | static TLS block | alignment, memsz; initialisation image copied per thread |
| `PT_GNU_STACK` | stack executability request | **ignored for authority**: Kynox never maps an executable stack without an explicit, audited grant |
| `PT_INTERP` | dynamic loader path | only Kynox's `KLD` is honoured; the name in the binary is matched, not executed from disk |

The parser is pure code with no kernel calls, fuzzable, and shared with the
native KEX loader where the concepts overlap.

### 3.2 Initial process state

- Stack layout per the psABI: `argc`, `argv[]`, `envp[]`, `auxv[]`, alignment
  `16` at the entry point `[S21]`.
- `AT_*` entries are generated from Kynox state: page size, entry point, phdr
  address, UID/EUID/GID/EGID (synthetic, §8), random bytes, HWCAP, platform.
- The `AT_RANDOM` 16 bytes come from the kernel CSPRNG; `AT_HWCAP` reports the
  features the CPU actually has — no invented flags.
- No `vDSO` pointer until KVD exists (§7.4); binaries that require it are
  rejected with a diagnostic, not silently mis-executed.

## 4. Calling convention

KLC does not change the machine ABI: x86-64 SysV (arguments in `rdi`, `rsi`,
`rdx`, `rcx`, `r8`, `r9` for integers, `xmm0–7` for floats, red zone, 16-byte
stack alignment at call sites) `[S21]`. What Kynox must provide is that its
**native code paths obey the same rules** when called from a compatible process:
the syscall entry, signal delivery and the dynamic loader all preserve the
registers the psABI says they must.

Divergence from this is a bug, not a design choice: there is exactly one
user-space ABI in the process, and the compatibility layer adds contracts, not
conventions.

## 5. Syscall interface: the translation problem

### 5.1 Why this is the hard part

A Linux x86-64 program invokes syscalls with the `syscall` instruction, number in
`rax`, arguments in `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`, returning a value in
`rax` where `-4095…-1` means `-errno`. The kernel is the only component that can
intercept that instruction. Unlike Windows, where applications normally call
through `ntdll`, Linux applications — especially static ones — execute the trap
directly. There is no user-space place to put a translation layer.

Linux's userspace ABI is explicitly documented as append-only: interfaces are
"expected to never change and always be available" `[S25]`, which is why the
numbers must be honoured exactly.

### 5.2 Options considered

| Option | How it works | Verdict |
|---|---|---|
| **A. Kernel personality table** | The kernel recognises a "Linux personality" task flag, dispatches the Linux number to a translation routine | Fast; but puts foreign ABI knowledge in the kernel and grows it forever |
| **B. Upcall to a user-space personality service** | Kernel traps, validates, and forwards to a user-space handler | Keeps policy out of the kernel; costs at least one extra switch per syscall; cannot handle high-frequency calls cheaply |
| **C. Hybrid, staged (chosen)** | Tiny kernel gate + fast-path table for the hot, security-critical operations; user-space service for the rest | Bounded kernel surface, measurable cost, migration path to B |

### 5.3 Decision (ADR-0010)

1. The kernel gains **one generic personality gate**, not Linux knowledge: a
   task carries a personality identifier and a validated table of
   `(number → handler kind)`. The gate copies arguments, validates user pointers
   through the normal `user_access` path, and dispatches.
2. **Stage 1** implements ~20 syscalls in-kernel through that gate, enough for a
   static "hello, world" and a static test corpus: `read`, `write`, `openat`,
   `close`, `mmap`, `munmap`, `mprotect`, `brk`, `exit`, `exit_group`,
   `clock_gettime`, `getpid`, `gettid`, `rt_sigaction`, `rt_sigprocmask`,
   `futex`, `clone` (thread subset), `execve`, `wait4`, `uname`.
3. **Stage 2** adds a user-space personality service for families where policy
   dominates (filesystem path resolution through the namespace service, `/proc`
   generation, networking) via an upcall interface that batches where possible.
4. The gate is **audited as a security boundary**: every handler validates
   pointer ranges, sizes, flags and object rights; unknown numbers return
   `ENOSYS` and are counted.
5. **The native syscall ABI is untouched.** KLC numbers live in their own table;
   nothing in `shared/syscall_abi.zig` changes because of compatibility.

### 5.4 Translation table (families, not a promise)

| Family | Examples | Native mechanism | Notes |
|---|---|---|---|
| Process | `clone`, `execve`, `exit`, `wait4`, `getpid` | task/process API | `clone` flags mapped; unsupported flags → `EINVAL` |
| Memory | `mmap`, `munmap`, `mprotect`, `brk`, `mremap` | VMM regions | `MAP_FIXED` honoured only within the process's own space |
| Files | `openat`, `read`, `write`, `stat`, `getdents64`, `renameat2` | VFS + namespace | path resolution inside the compatibility root |
| Polling | `epoll_create1/ctl/wait`, `poll`, `ppoll`, `eventfd` | IPC + wait queues | epoll implemented natively, not emulated per call |
| Time | `clock_gettime`, `nanosleep`, `clock_nanosleep` | time subsystem | monotonic and realtime classes |
| Sync | `futex` | user-address wait/wake primitive | 32-bit futex word semantics `[S26]` |
| Signals | `rt_sigaction`, `rt_sigprocmask`, `rt_sigreturn`, `kill`, `tgkill` | signal subsystem | frame layout must match what the binary's restorer expects |
| Threads | `clone` with `CLONE_THREAD`, `set_tid_address`, `rseq` | scheduler | TLS setup through `CLONE_SETTLS` |
| Sockets | `socket`, `bind`, `connect`, `sendto`, `recvfrom`, `poll` | network service | AF_INET/AF_INET6/AF_UNIX subset |
| Info | `uname`, `sysinfo`, `getrandom`, `prctl` (subset) | kernel | values must be truthful, not a fake "Linux 6.x" |

## 6. Signals

Signals are the second-hardest contract after syscalls.

- **Delivery**: the kernel builds a Linux-shaped signal frame (`ucontext`,
  `siginfo`, `fpregs`), places it on the user stack (or alternate stack if
  `SS_ONSTACK` semantics require it), and transfers control to the handler.
- **Restorer**: the application's restorer address (`sa_restorer`) must be
  invoked after the handler returns; the frame layout is therefore part of the
  ABI and is versioned.
- **Masking**: `sigprocmask`, `sigaction` flags (`SA_RESTART`, `SA_SIGINFO`,
  `SA_NODEFER`, `SA_ONSTACK`), `sigsuspend`, `sigwaitinfo` map to the native
  signal subsystem.
- **Synchronous faults**: `SIGSEGV`, `SIGBUS`, `SIGFPE`, `SIGILL` from a fault
  in compatibility code are converted into the Linux siginfo layout.
- **`SIGKILL`/`SIGSTOP`** keep their unblockable semantics.

Non-negotiable rule: a signal handler runs with exactly the capabilities the
process already has. Delivering a signal never escalates privilege.

## 7. Memory, threads and libraries

### 7.1 Memory semantics

| Linux behaviour | Kynox mapping |
|---|---|
| Anonymous `mmap` | VMM region with `MAP_ANONYMOUS` semantics |
| File-backed `mmap` (shared/private) | VFS mapping with a page cache; `MAP_PRIVATE` is COW |
| `MAP_FIXED` | allowed only inside the process's own address space; never relocates another mapping silently |
| `MAP_GROWSDOWN` stack | stack region with a guard page and growth policy |
| `mremap` | region resize or move; `MREMAP_FIXED` validated |
| `brk`/`sbrk` | simulated on top of a heap region, since native Kynox has no `brk` |
| `PROT_EXEC` | W^X enforced by policy; an executable mapping request may be refused and reported |

### 7.2 Threads and TLS

- `clone(CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SETTLS)`
  maps to a native thread with a shared address space.
- TLS variants: initial-exec and local-exec are resolved by the loader;
  general-dynamic/local-dynamic require a working `__tls_get_addr` in KLIBC,
  backed by the native TLS area.
- `rseq` and `getcpu`: modern glibc uses restartable sequences for per-CPU data.
  Without `rseq` support, thread-local fast paths degrade but must not crash;
  the support matrix records the state.
- **Robust futex list**: a thread that dies while holding a robust mutex must
  wake waiters with `EOWNERDEAD`. Kynox implements the list walk in the kernel's
  futex support `[S26]`.

### 7.3 Dynamic linking and libraries

- **KLD** (Kynox Linux Dynamic loader) implements the observable `ld.so`
  contract: `PT_INTERP`, dependency resolution, `DT_RPATH`/`RUNPATH`,
  symbol versioning (`.gnu.version_r`, `.gnu.version_d`), relocations
  (`R_X86_64_*` subset), `DT_INIT`/`DT_FINI` arrays, `LD_LIBRARY_PATH`.
- `LD_PRELOAD` and `LD_AUDIT` are **disabled by default** inside the sandbox:
  they are code-injection mechanisms, and a package that needs them declares it.
- **KLIBC**: Kynox's own implementation of the C library ABI surface that
  applications actually link against — not glibc and not musl. It provides the
  documented symbol set with the documented semantics: memory, strings, stdio,
  `pthread_*`, `dlopen`/`dlsym`, time, locale-free basics, `getaddrinfo` over the
  native network service.
- **Versioned symbols**: applications built against glibc 2.34 expect
  `GLIBC_2.34` version tags on many symbols. KLIBC must export the version
  definitions the ABI requires; this is a compatibility surface, not a claim to
  be glibc.

Why not bundle glibc or musl: it would import a foreign runtime, its TLS and
loader assumptions, its bug surface and its licence into the platform's trust
base — exactly what `KYNOX_NATIVE.md` forbids. KLIBC is smaller because it only
implements what the published matrix supports.

### 7.4 vDSO

Linux maps a small DSO into every process (`__vdso_clock_gettime`,
`__vdso_gettimeofday`, `__vdso_time`, `__vdso_getcpu`). Programs and libraries
call those symbols directly for speed.

Kynox provides **KVD** — a hand-built ELF DSO with an ABI-compatible symbol set,
mapped at process start and advertised through `AT_SYSINFO_EHDR`. It calls into
the native time/getcpu paths. Until KVD exists, `AT_SYSINFO_EHDR` is absent and
the support matrix says so; a binary that requires the vDSO is rejected.

## 8. Filesystem, namespace and permissions

- The compatible process sees a **compatibility root**: a namespace overlay that
  presents `/usr`, `/lib`, `/lib64`, `/etc`, `/tmp`, `/dev`, `/proc`, `/sys` and
  a writable home directory.
- **`/proc` and `/sys` are synthetic**: a read-only service generates
  `self/maps`, `self/stat`, `self/status`, `self/fd/`, `cpuinfo`, `meminfo`,
  `mounts`, `version` from native state. Values are truthful; nothing pretends
  to be a Linux kernel version that does not exist.
- **Permissions**: Linux `uid`/`gid` and mode bits are **advisory inside the
  sandbox**. The real authority is the capability set the process holds. A file
  readable by its mode bits is still unreadable without the directory
  capability. This is a deliberate deviation: the alternative (POSIX permissions
  as authority) would create a second security model, which
  [`security-architecture.md`](security-architecture.md) §1 forbids.
- UID/GID values are synthetic per sandbox and stable for the process lifetime;
  `chown` is a no-op that returns success only for values the sandbox can model,
  and `EPERM` otherwise.
- Mount operations are denied unless the calling package declared a mount
  capability; there is no ambient root.

## 9. IPC, sockets and the rest of the surface

- Pipes and UNIX sockets map to native IPC channels with file-descriptor
  semantics (dup, CLOEXEC, O_NONBLOCK).
- `epoll` is implemented natively as a wait set over native objects; it is not
  emulated with polling loops.
- `eventfd`, `timerfd`, `signalfd` map to native objects with the same
  observable semantics.
- SysV IPC (`shm`, `msg`, `sem`) is **not** in the first matrix; it is a
  documented gap.

## 10. Process model and lifecycle

- `fork` is implemented as `clone(CLONE_VM off)` where the native VMM supports
  COW; if it does not, `fork` is refused rather than emulated with `posix_spawn`
  workarounds that break semantics.
- `execve` replaces the image inside the same process, preserving PID and file
  descriptors with `FD_CLOEXEC` handling.
- `wait4`, zombie reaping, `SIGCHLD` and process groups follow Linux semantics.
- `/proc/self/exe`, `cwd`, `umask` and `rlimit` are honoured.
- cgroups, namespaces and seccomp are **not** exposed as Linux mechanisms; the
  sandbox is the Sandbox (§11), and an application that needs to create
  namespaces is refused.

## 11. Security model

| Property | Mechanism |
|---|---|
| No privilege gain from a foreign ABI | the persona has exactly the capabilities granted at exec; no syscall can add one |
| Memory isolation | per-process address spaces; the personality cannot map physical memory |
| Syscall surface control | per-persona allow-list; unknown numbers return `ENOSYS` and are counted |
| Filesystem containment | compatibility root + capability-checked VFS; no ambient `/` |
| Device access | only through delegated capabilities (DRM-like device objects, audio streams) |
| Resource limits | CPU time, memory, GPU memory, process count, open objects |
| Audit | every denied syscall, path escape attempt and capability check is logged with the persona id |
| Graphics | layers run unprivileged; GPU memory is per-process (graphics-compatibility §7) |

Threat model additions specific to KLC:

- **Hostile ELF**: crafted headers, overlapping segments, recursion in the
  loader, huge `PT_LOAD` counts — handled by strict validation and fuzzing.
- **Hostile shader/GLSL**: compiled by Kynox's own front-end with a validator;
  no arbitrary machine code generation.
- **Malicious library**: libraries are just code in the process; they cannot
  exceed the process's capabilities, but they can attack the persona runtime
  itself — so the persona runtime is written defensively and shares no memory
  with the kernel.

## 12. Performance

Translation cost is expected and must be measured, not denied:

- Every syscall crosses an additional dispatch table; the target is a documented
  number of nanoseconds per call per family, benchmarked against a bare native
  syscall **on Kynox** (not against Linux, which would be meaningless).
- `epoll` and `futex` are the two hot paths in real applications; both are native
  implementations, not loops.
- vDSO-equivalent fast paths (`KVD`) exist precisely to keep `clock_gettime` out
  of the kernel.
- `fork` + COW is expensive by nature; the matrix reports it, and applications
  that use it heavily are flagged.

Forbidden: "native performance", "zero overhead". Required: measured deltas with
a scenario.

## 13. Support matrix (the only thing that may be published)

| Dimension | Values |
|---|---|
| Architecture | x86-64 only |
| ELF class | ELF64, LSB, static and dynamic (dynamic only once KLD+KLIBC pass) |
| Kernel interfaces | enumerated syscall list with version |
| Libraries | KLIBC symbol list with versions |
| Graphics | none / OpenGL N / Vulkan N (from the respective matrices) |
| Windowing | none / X11 bridge / Wayland bridge |
| Known exceptions | per-application, with the failing contract |

A program enters the matrix only after its automated test passes on the
reference machine; a failed test stays visible.

## 14. Phases

| Phase | Objective | Exit criterion |
|---|---|---|
| C-L0 | ELF64 static loader + ~20 syscalls | static "hello" and a 10-program corpus run under the emulator suite |
| C-L1 | process/threads/signals/futex | a static multithreaded program passes; faults map to correct signals |
| C-L2 | filesystem, `/proc` subset, epoll | a static file-serving test program passes |
| C-L3 | KLD + KLIBC core (memory, strings, stdio, pthread) | a dynamically linked program built against KLIBC runs |
| C-L4 | glibc-ABI dynamic programs (versioned symbols, TLS models) | published list of programs, each with a test |
| C-L5 | graphics: KGL/KVK + window bridge | a windowed OpenGL/Vulkan test application runs |

Phases C-L0…C-L3 map to compatibility roadmap C1–C3; C-L5 maps to C9.
Full criteria, tests, risks and evidence requirements are in
[`../roadmap/COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md).

## 15. Open questions

1. Does the kernel gate accept *all* Linux numbers and let the user-space
   service decide, or does it reject unknown numbers immediately?
2. Is KLIBC one library or a set of versioned lanes (e.g. `KLIBC_2.17`,
   `KLIBC_2.34`) matching glibc symbol versions?
3. How far must `/proc` fidelity go before real programs stop probing it?
4. Is X11 support worth the complexity, or is Wayland-only honest for version
   one?
5. `fork` on a microkernel-ish native VMM: implement COW properly, or declare
   `fork` unsupported in the first matrix?
6. Do we accept `ptrace` for debuggers, and under which capability?
