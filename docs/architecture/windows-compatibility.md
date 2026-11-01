# KWC — Kynox Windows Compatibility layer

- Status: **planning document**. Nothing here is implemented; KWC is 0%.
  Kynox does **not** run Windows binaries today and makes no compatibility claim.
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md) §4.5, §4.9,
  [`application-ecosystem.md`](application-ecosystem.md) §8,
  [`graphics-compatibility.md`](graphics-compatibility.md) §8, §10,
  [`security-architecture.md`](security-architecture.md) §8,
  [`linux-compatibility.md`](linux-compatibility.md),
  ADR-[0010](../decisions/0010-compatibility-execution-model.md),
  [`../roadmap/COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md).

## 1. What KWC is, and what it is not

KWC runs **unmodified Windows x86-64 PE32+ executables** on the Kynox kernel by
implementing the platform contracts those binaries depend on.

It is not a Windows kernel, not a VM, not Wine and not a reimplementation of
Windows. There is no NT kernel underneath, no Microsoft binary is redistributed
or executed, and no component of Windows is a runtime dependency.

The scope statement:

> KWC is an incremental matrix of image formats, calling conventions, NT
> services, Win32 APIs, object semantics and graphics. Loading a PE, resolving
> its imports or showing a window are three different milestones, none of which
> equals "Windows compatibility".

## 2. Why Windows is different from Linux (and why that matters)

| Property | Linux (KLC) | Windows (KWC) |
|---|---|---|
| System entry | applications execute `syscall` directly | applications call `ntdll.dll` exports, which execute `syscall` **inside** ntdll |
| ABI surface | a few hundred syscalls, stable by number `[S25]` | several hundred NT services, mostly undocumented, plus documented Win32 |
| Binary interface | ELF + SysV psABI | PE32+ + Microsoft x64 ABI `[S23]` |
| Exception model | DWARF unwind in user space | `.pdata`/`.xdata` table-driven unwind, SEH `[S24]` |
| Object model | file descriptors + paths | handles into a per-process table with access masks |
| Window system | X11 / Wayland protocols | `user32` + GDI + DWM composition |

The important architectural consequence: **Windows applications do not need a
kernel trap translator** for the normal case, because the syscall boundary is
inside a library Kynox provides. KWC therefore implements `ntdll` as a user-space
library over Kynox syscalls — a fundamentally smaller kernel commitment than
KLC's gate. The trade-off is that any application that bypasses ntdll (anti-cheat,
DRM, some protectors) is outside the supported model, and is documented as such
rather than chased.

## 3. The five separated contracts

| # | Contract | Content | Independent test |
|---|---|---|---|
| 1 | Image format | PE32+ headers, sections, relocations, imports, TLS, `.pdata` | parser corpus |
| 2 | Calling convention | Microsoft x64: `rcx`, `rdx`, `r8`, `r9`, 32-byte shadow space, nonvolatile `rbx`, `rbp`, `rdi`, `rsi`, `r12–r15`, `xmm6–15` `[S23]` | call harness |
| 3 | NT services | `ntdll` `Nt*`/`Zw*` subset over Kynox objects | per-service tests |
| 4 | Win32 API | `kernel32`/`kernelbase`, `user32`, `gdi32`, `advapi32`, CRT | per-API tests |
| 5 | User-space behaviour | registry, paths, environment, locale, error codes | application corpus |

## 4. PE32+ loader

### 4.1 What must be parsed and validated

| Structure | Use | Validation |
|---|---|---|
| DOS header + `e_lfanew` | locate `PE\0\0` | bounds, signature |
| COFF header | machine = `0x8664`, section count, characteristics | reject non-x64, DLL flags |
| Optional header | magic `0x20B` (PE32+), entry point, image base, alignment, subsystem, `DllCharacteristics` | alignment power of two, `SizeOfImage`, no overlapping sections `[S22]` |
| Section table | `.text`, `.rdata`, `.data`, `.pdata`, `.rsrc`, `.reloc`, `.tls` | virtual/physical sizes, W^X split, RVA bounds |
| Base relocations | `IMAGE_REL_BASED_DIR64`, `HIGHLOW`, `ABSOLUTE` | count, bounds, applied only to writable pages |
| Import table | DLL name + function name/ordinal per thunk | forwarder depth limit, reject unresolved without diagnostic `[S22]` |
| Delay import | `IMAGE_DELAYLOAD_DESCRIPTOR` | resolved lazily, same validation |
| TLS directory | callback array, index slot | bounds; callbacks called in order at attach/detach |
| Exception table | `.pdata` `RUNTIME_FUNCTION` + `.xdata` `UNWIND_INFO` | used by the unwinder; malformed data is a load error |
| Load config | `SEHandlerTable`, `GuardCF*` | safe-SEH and CFG tables parsed; CFG enforcement is **not** claimed |
| Resources | `.rsrc` tree | parsed for icons, manifests, version info |
| Manifest | embedded or `app.manifest` | requested privileges are ignored for authority; they are translated into a diagnostic |

### 4.2 Loading model

- Sections map at `ImageBase` when free; otherwise the loader relocates and
  applies base relocations (an image without `.reloc` that cannot load at its
  base is rejected).
- `W^X` is enforced: `.text` never writable, `.data` never executable. A
  packed binary that writes and executes the same page is refused with a
  diagnostic rather than given an RWX mapping.
- Imports resolve against KWC's DLL set; a missing DLL or export is a load
  failure with the name and the importing module, not a silent stub.
- **No stub may pretend to succeed.** A function returning success without doing
  the work is worse than refusing to load, because it produces silent data loss.

## 5. Process, threads and the TEB

- **Process**: `PEB` with documented fields (image base, command line,
  environment, loader data, `ProcessParameters`), plus a `KWC` private area.
- **Thread**: `TEB` at `GS:[0]` with `NtTib` (SEH list head, stack base/limit),
  `ClientId`, `ThreadLocalStoragePointer`, `LastErrorValue`, and the TLS slots.
  The TEB is per-thread memory owned by the persona runtime.
- **Thread creation**: `CreateThread`/`_beginthreadex` map to native threads with
  a documented stack reservation/commit rule.
- **Process creation**: `CreateProcessW` maps to the native process API; the
  child inherits handles explicitly, never ambiently.
- **Job objects**: partial support later (limits map to sandbox quotas).
- **DLL loading**: `LoadLibrary`/`GetProcAddress` map to the KWC loader; search
  order is documented and does not include the current directory by default
  (a classic hijacking vector).

## 6. Handles and objects (KOB)

Windows handles are process-local indices with an access mask, not pointers.
Kynox models this explicitly:

| NT concept | Kynox implementation |
|---|---|
| `HANDLE` | index into a per-process table owned by KOB (user space) |
| Object type | `File`, `Section`, `Event`, `Mutant`, `Semaphore`, `Process`, `Thread`, `Key`, `IoCompletion`, `Token` |
| Access mask | `GENERIC_*` translated to rights on the backing Kynox capability |
| Duplicate/close | `DuplicateHandle`, `CloseHandle` with reference counting |
| Wait | `WaitForSingleObject`/`WaitForMultipleObjects` map to native wait sets |
| Security descriptor | parsed for ACL checks **inside the sandbox**; the real authority remains the capability |
| Inherit | explicit only; handle inheritance is opt-in per handle |

A Windows handle never maps directly to a kernel capability handle: KOB is the
translation table, and it can only open what the persona already holds. A
process that guesses a handle number gets its own table entry or
`INVALID_HANDLE_VALUE`, never another process's object.

## 7. ntdll, kernel32, kernelbase

- **KNTDLL** implements the `Nt*`/`Zw*` surface that applications and Win32
  libraries actually use: memory (`NtAllocateVirtualMemory`,
  `NtProtectVirtualMemory`, `NtMapViewOfSection`), objects
  (`NtCreateEvent`, `NtWaitForSingleObject`), files
  (`NtCreateFile`/`NtReadFile`/`NtWriteFile`), process/thread, registry keys,
  time, and the loader functions used by `LdrLoadDll`.
- **kernel32/kernelbase** are implemented on top of KNTDLL: file I/O, memory,
  synchronisation, environment, console, error codes, `GetLastError` and
  `SetLastError` in the TEB.
- **No `syscall` instruction translation** is needed for the normal path; this
  is stated as an architectural advantage and a documented limit: software that
  issues NT syscalls directly is out of scope.

## 8. CRT and runtime

- `msvcrt.dll`, `ucrtbase.dll`, `vcruntime140.dll` equivalents implement the C
  runtime surface applications link against: startup, `malloc` (over native
  memory), stdio, string/memory, `setjmp`, C++ exceptions plumbing
  (`__CxxThrowException`, `_except_handler4`), `__security_cookie`, and
  `_initterm` callbacks.
- Static CRT applications need only the API surface they import; dynamic CRT
  applications need the DLL set.
- **No redistribution of Microsoft binaries.** Every DLL is Kynox's own
  implementation of the documented contract.
- .NET, Java, Electron and other large runtimes are **explicitly out of scope**
  for the first matrix: they would require additional platform contracts
  (CLR, JIT, COM+, WinRT) and are their own projects.

## 9. Exceptions, SEH and unwind

- `.pdata`/`.xdata` drive stack unwinding; Kynox implements the unwind opcodes
  used by MSVC and clang-cl, and validates the tables at load time `[S24]`.
- `RaiseException`, `AddVectoredExceptionHandler`,
  `SetUnhandledExceptionFilter`, `__try/__except/__finally` and C++ `catch`
  all funnel through one dispatcher.
- The **unwinder is a compatibility component**, not a kernel facility. A
  malformed unwind table must fail the load or terminate the process cleanly; it
  must not walk the kernel stack or read outside the process.
- `StackWalk`-style debugging is a later tool, not a requirement for running.

## 10. Registry, paths and configuration

- The registry is a **per-application hive**: `HKCU` and `HKLM` writes are
  redirected into a package-scoped store unless the package declares a
  system-wide need.
- Legacy installers that write to `HKLM` get **registry virtualisation** into
  their own hive, which is the documented behaviour expected by those
  applications and keeps the system store clean.
- Paths: `%WINDIR%`, `%SYSTEMROOT%`, `%PROGRAMFILES%`, `%APPDATA%`, `%TEMP%`
  map into the compatibility root. Drive letters are a namespace view, not a
  block device model.
- `GetSystemInfo`, `GetVersionEx`, `RtlGetVersion` report values that match the
  compatibility level KWC declares. Declaring a Windows version is a
  compatibility decision with an explicit matrix entry, not a hardcoded lie.

## 11. user32, GDI, and the window system

| Layer | Mapping |
|---|---|
| `user32` windows | KWM surfaces (top-level, child, popup) with a Win32 state machine on top |
| Messages | `WM_*` queue per thread; input translated from KWM events |
| `gdi32` drawing | KGA-UI (2D layer): rectangles, text, bitmaps, clipping regions |
| Fonts | system font service; glyph rasterisation owned by Kynox |
| Clipboard | KWM clipboard protocol |
| DPI/scaling | KWM scaling policy; per-monitor awareness translated |
| `Dwm*` APIs | reported as available with documented limitations; composition is always on |

GDI is a retained-mode drawing API mapped onto an immediate-mode 2D layer. This
is a real translation cost and must be measured; CAD-like applications that draw
heavily through GDI will be slower than native ones, and the matrix says so.

## 12. COM, RPC and system services

- **COM**: `ole32`/`oleaut32` subset — `CoInitializeEx`, `CoCreateInstance`,
  `IUnknown` plumbing, apartment threading (`STA`/`MTA` mapped to native
  threads), `IDispatch` late binding, type libraries (`.tlb`) for the subset.
  COM is required by installers, shell integration and many applications; it is
  a phase of its own.
- **RPC**: `rpcrt4` subset for local RPC (LRPC) only; network RPC is out of
  scope initially.
- **Services**: the Windows Service Control Manager is modelled as Kynox
  services with a compatibility view; a Windows service runs as a supervised
  Kynox service with declared capabilities.
- **Winsock**: `ws2_32` over the native network stack, blocking and
  `WSAEventSelect`/`select` first, overlapped I/O and IOCP later.

## 13. Graphics: OpenGL, Vulkan, Direct3D

| Path | Requirement | Phase |
|---|---|---|
| OpenGL applications | `opengl32.dll` → KGL, WGL → KWM surface | with KGL |
| Vulkan applications | `vulkan-1.dll` → KVK, `VK_KHR_win32_surface` equivalent | with KVK |
| Direct3D 9 | fixed-function + shader model 2/3 → KGL (best semantic fit) | after KGL 3.3 |
| Direct3D 10/11 | state translation → KGX; HLSL → SPIR-V via Kynox front-end | after KVK 1.1 |
| Direct3D 12 | close mapping to KVK semantics; descriptor heaps, root signatures, bundles | after KVK 1.3 + descriptor model |
| DXGI | swapchain/factory/adapters → KWM/KDS; `IDXGIFactory` surface enumeration | with D3D 10+ |

D3D is **not** in the critical path (§[`COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md) §7).
Prerequisites are architectural, not cosmetic:

1. KGX must express D3D12's descriptor model and root-signature binding without
   a translation layer that changes semantics.
2. HLSL must compile to the canonical shader format; that front-end does not
   exist and is a project on its own.
3. D3D9's fixed-function pipeline reuses KGL's generated-shader library.

## 14. Security model

| Risk | Control |
|---|---|
| Hostile PE (malformed headers, overlapping sections, RVA overflow) | strict validation, fuzzing corpus, bounds-checked parser |
| Handle escalation | KOB is per-process; handles never escape their table; access masks map to existing rights |
| DLL hijacking | documented search order, no current-directory default, signed system DLL set |
| Registry poisoning | per-app hives, virtualised writes, no ambient `HKLM` write |
| SEH abuse | unwind tables validated; unwinder never leaves the process |
| COM activation | class registration scoped per package; no system-wide registration without a declared capability |
| Third-party anti-cheat / DRM | **out of scope**; a title relying on kernel drivers or undocumented syscalls is documented as unsupported |
| Graphics | unprivileged layers; per-process GPU memory; no Ring 0 shims |

Explicit non-guarantees:

- KWC does **not** promise that any specific game or application runs.
- KWC does **not** implement Windows kernel drivers (`.sys`).
- KWC does **not** provide `ntoskrnl` semantics, kernel callbacks, or
  `DeviceIoControl` to real drivers.
- KWC does **not** claim binary compatibility for anti-cheat-protected titles.

## 15. Performance

- The normal path is a direct call into a Kynox DLL: the CPU cost is the work
  itself plus the KOB lookup, not a trap per API call.
- The expensive paths are: GDI drawing (translation to 2D), COM apartment
  marshalling, and overlapped I/O; each has a benchmark and a published number.
- A Windows application that polls (`Sleep(0)`, `MsgWaitForMultipleObjects`)
  must not burn a core; the scheduler treats compatibility processes like any
  other and the matrix flags pathological patterns.

## 16. Phases

| Phase | Objective | Exit criterion |
|---|---|---|
| C-W0 | PE parser + loader (no execution) | 200-image corpus parses; malformed corpus rejected with diagnostics |
| C-W1 | console "hello" (kernel32 file/write/exit) | static console binary runs under the emulator suite |
| C-W2 | memory, threads, sync, TLS, error codes | multithreaded console test suite passes |
| C-W3 | SEH/unwind + CRT + C++ exceptions | C++ test binary throws/catches across DLL boundaries |
| C-W4 | user32 + GDI + KWM surface | window opens, paints, receives input |
| C-W5 | COM subset + registry virtualisation | installer-like workload completes |
| C-W6 | OpenGL/Vulkan paths | windowed GL/VK test application runs |

Phases C-W0…C-W3 map to compatibility roadmap C4–C5; C-W4/C-W5 map to C10;
C-W6 maps to C7–C9. Details in
[`../roadmap/COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md).

## 17. Open questions

1. How much of the TEB/PEB layout must be reproduced before real applications
   stop crashing? (Documented fields only, or the de-facto layout?)
2. Is `LoadLibrary` search order configurable per package, or fixed?
3. Do we support `WOW64`-style 32-bit PE at all? (Current answer: no; x86-64
   only, documented.)
4. Which Windows version does `RtlGetVersion` report, and does that change per
   application profile?
5. Is COM STA threading compatible with Kynox's scheduler without a dedicated
   message-pump thread model?
6. Can GDI be fast enough for CAD, or is the honest answer "native applications
   only for CAD"?
