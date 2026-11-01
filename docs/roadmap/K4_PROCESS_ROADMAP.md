# K4 — Process Model and Userspace Execution Roadmap

Status: **design / not started**.
Reference: `docs/decisions/ADR-K4-001-process-architecture.md`, `docs/architecture/k4-process-model.md`.

## Dependency graph (simplified)

```
K3.12.2 audit fix (scheduler + SMP)
  ↓
K3.12.4 audit fix (wait.zig + runqueue.zig + preempt_disable)
  ↓
K4.0  Process architecture (design only)
  ↓
K4.1  Process object + handles
  ↓
K4.2  Lifecycle (create, exit, reap)
  ↓
K4.3  Process/thread integration (requires scheduler fix + SMP fix)
  ↓
K4.4  User address space + Ring 3 transition
  ↓
K4.5  Memory validation + safe copy
  ↓
K4.6  ELF64 loader
  ↓
K4.7  Native executable (KEX)
  ↓
K4.8  Process syscalls
  ↓
K4.9  Parent/child + wait/reap (requires wait.zig)
  ↓
K4.10 Security + isolation hardening
```

Each stage must complete its evidence (P → F → E → H) before the next stage claims integration. No stage may claim `validated` without QEMU/hardware evidence.

## Evidence ladder

- **P (Planning)**: contracts defined (this document, `k4-process-model.md`, ADR-K4-001).
- **F (Functional)**: module builds; host unit tests pass.
- **E (Execution)**: `zig build qemu-test` passes with relevant markers.
- **H (Hardware)**: runs on physical hardware with named device; no regression.
