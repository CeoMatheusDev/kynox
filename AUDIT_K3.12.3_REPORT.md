Audit K3.12.3 — Context Switching and FPU

Files inspected:
- kernel/task/context.zig (fp_state_size=512, fp_state_offset=192, align(64); assertions present)
- kernel/arch/x86_64/task.s (frame layout 176 bytes; fxrstor64 @ 192; fxsave64 in capture)
- kernel/arch/x86_64/interrupt.s (PUSH_REGISTERS / POP_REGISTERS; ALIGN_STACK / UNALIGN_STACK)
- kernel/arch/x86_64/segment.zig (TSS assertions for rsp0/rsp1/rsp2/ist1; tss_size=104)
- kernel/arch/x86_64/cpu.zig (enableFloatingPoint: CR0 EM/MP/TS; CR4 OSFXSR/OSXMMEXCPT)
- kernel/task/scheduler.zig (no changes)

Defects / gaps recorded (NOT fixed in this branch — design decision blocked):
- No `fpu.zig` exists; FPU management is embedded in `context.zig` and `cpu.zig`, not isolated.
- `context.zig` defines fp_state_size and offset but there is no runtime verification that `fxrstor64` aligns with the actual `fp` area (host tests do not execute privileged FPU instructions).
- `task.s` uses `fxrstor64 192(%rsi)` without an explicit `l1om` or `alignas` assertion at the assembly site; the alignment relies on Zig `align(64)` on the struct.
- TSS assertions exist (`segment.zig`) but no runtime verification of `ist1` or `rsp0` after `install` is executed in this environment.
- No per-CPU `idle` context or `capture_context` integration tested under QEMU here.
- `cpu.zig` enables FPU without an explicit CPUID feature check (assumes x86-64 always has x87/SSE); safe for baseline architecture but should be documented.

Tests added:
- tests/context_fpu_regression.zig (host-only structural assertions for offsets, sizes, alignment)

No QEMU execution performed (environment has no QEMU/OVMF).
No K4 work started.
Branch: audit/k3-12-3-context-fpu
