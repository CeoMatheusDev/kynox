# ADR-0010 · Compatibility execution model: unprivileged personalities, one narrow kernel gate

- Status: **accepted for planning**. No personality, gate or loader exists.
- Date: 2026-10-31.
- Related: [`linux-compatibility.md`](../architecture/linux-compatibility.md) §5,
  [`windows-compatibility.md`](../architecture/windows-compatibility.md) §2–§7,
  [`security-architecture.md`](../architecture/security-architecture.md) §8,
  [`COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md) C0–C5,
  [`KYNOX_NATIVE.md`](../../KYNOX_NATIVE.md) §4.

## Context

Running foreign binaries requires deciding **where the foreign contracts are
implemented**. Four families of answer exist in the industry:

- a foreign kernel (WSL1, Linux itself): forbidden by project policy;
- a virtual machine with a foreign kernel (WSL2, VM-based compatibility):
  possible but does not run the binary natively and adds a second kernel to
  trust and maintain;
- a Ring 0 personality inside the native kernel (some compatibility layers load
  kernel modules): puts foreign ABI knowledge in the most privileged ring;
- user-space translation over a small kernel interface: the binary runs natively
  on the CPU, and the kernel only provides generic mechanisms.

Linux and Windows differ in where their ABI boundary sits. Linux applications
trap directly (`syscall` instruction), so the kernel must offer *some* entry
point. Windows applications call `ntdll`, so the boundary can be a library Kynox
provides — no kernel knowledge of NT is required for the normal path.

## Options

**A. Kernel-side personalities, one per system.**
Fast; but the kernel accumulates two foreign ABIs forever, and every security
review of the kernel must include them. Rejected.

**B. Full virtualisation for both.**
No ABI work, but the user gets a VM, not native execution; performance and
integration (graphics, files, clipboard) degrade, and it contradicts the goal of
running applications *on Kynox services*.

**C. Unprivileged personality runtimes over one generic kernel gate (chosen).**
The kernel exposes a single, small, ABI-agnostic trap path plus generic
primitives (user-address waits, handle tables, copy-in/out validation). Linux
personality translation happens behind that gate; the Windows personality does
not need the gate at all because its boundary is a library.

## Decision

Adopt **C**, with these rules:

1. **No foreign ABI in the kernel.** The kernel implements one generic
   "personality gate": a per-task descriptor validated at exec, a bounded
   dispatch table and hardened argument copying. It contains no Linux or Windows
   semantics.
2. **Personalities live in user space.** KLC and KWC are libraries and services
   inside the compatible process (plus an optional personality service). They
   hold only the capabilities granted at exec.
3. **Staged translation (KLC).** The first matrix uses a small in-kernel handler
   set behind the gate (~20 calls) for static binaries; families dominated by
   policy move to a user-space service, with batching to control cost. Cost is
   measured, never assumed.
4. **Library-mediated translation (KWC).** `ntdll` and the Win32 DLLs are
   Kynox implementations over native syscalls; no `syscall` interception is
   attempted, and software that bypasses `ntdll` is out of scope by design.
5. **Capability ceiling.** A compatible process never gains a capability by
   executing a foreign ABI. It starts with the capabilities its package
   declared, exactly like a native application.
6. **Formats are parsed in user space, with validation.** ELF and PE parsers are
   pure code, fuzzed, and never trust a field. Mapping and execution go through
   the native process-creation path.
7. **Nothing foreign in Ring 0** — no Linux driver, no Windows driver, no
   anti-cheat kernel component, ever.

## Consequences

- Positive: the kernel's trusted surface grows by one small gate, not by two
  ABIs; personalities can be updated and even replaced without a kernel change;
  security review stays focused; Windows compatibility does not touch the kernel
  at all.
- Negative: KLC pays a dispatch/upcall cost on every syscall; the user-space
  service must be fast and careful; the kernel gate is still a new attack
  surface that needs its own fuzzing.
- Neutral: the "which kernel version do we report" question becomes a
  personality-policy decision, not a kernel one.

## Risks

| Risk | Mitigation |
|---|---|
| Gate becomes an unbounded foreign ABI | number budget per persona, review per family, counters for unknown calls |
| Syscall cost too high | measure per family; batch; in-kernel fast path only for calls whose semantics are generic |
| Personality escapes sandbox | capability ceiling; no ambient filesystem; every grant audited |
| Users expect Wine-class coverage | publish the matrix; refuse rather than stub |

## Reversal criteria

If the gate's measured cost exceeds the documented budget for `futex` and
`epoll` after optimisation, allow those two families a dedicated fast path in
the kernel while keeping their **semantics** in the personality — a performance
exception, not a policy change. A return to kernel-side personalities requires a
new ADR and a security review.
