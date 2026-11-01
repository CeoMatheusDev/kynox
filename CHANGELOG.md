# Changelog

All notable changes to Kynox are recorded in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)
with release tags prefixed by `v` (`v0.1.0-alpha.1`). Prereleases use the
`-alpha.N` / `-beta.N` / `-rc.N` suffixes.

Rules used for this file:

- Entries describe what the **tree** does, not intentions.
- Validation entries name the command and its result; a test that was not
  executed is listed as not executed.
- Maturity percentages are not changelog material; see `docs/PROJECT_STATUS.md`.

## [Unreleased]

Repository audit, governance and documentation for the first alpha, followed by
the P1 blockers of the alpha readiness phase (single version source, native ABI
contract, ACPI platform discovery) and the official identity scheme. Current
identity: **Kynox One 0.1.0-alpha.1**. No tag exists.

### Added (2026-11-01) — a máquina falha inteira: a IPI de parada e um caminho de falha só

- **O buraco**: todas as falhas fatais terminavam em `port.haltForever()`, que
  para **aquele** processador. Numa máquina com mais de um, as outras CPUs
  continuam escrevendo no mesmo serial — o relatório da falha sai intercalado
  com o trabalho normal, e um defeito que aconteceu uma vez vira um defeito
  impossível de reproduzir.
- **O vetor 67**: `apic.halt_vector`, `apic.sendHalt`, stub em `interrupt.s`,
  porta no IDT e um handler que encerra a interrupção, conta a parada e para a
  CPU.
- **`smp.stopOtherCpus()`** devolve um `StopReport` com os dois fatos que são
  diferentes — quantos processadores online existem (`targets`) e quantas IPIs
  foram realmente entregues ao controlador (`delivered`) — mais o caso
  `no_apic`, em que havia alvo e ninguém pôde ser avisado. A CPU que recebe não
  responde (ela para), então o relatório promete só o que pode.
- **`smp.describeStop`** formata a linha em um buffer do chamador, porque roda no
  caminho da falha, onde o alocador pode ser justamente o que quebrou.
- **`kernel/fatal.zig`**: um lugar só para morrer. `stopTheMachine(reason)` e
  `stopAfterReport()` substituem as 176 chamadas a `port.haltForever()` que
  estavam espalhadas (174 em `main.zig`, 2 em `interrupt.zig`), e acrescentam o
  aviso às outras CPUs antes da última linha.
- **Quatro testes de host** (845 no total, `arch-tests` 176): a máquina com um
  processador (ninguém a quem pedir, e a linha diz isso), a parada sem
  controlador (diz "none told to stop" em vez de fingir), o relatório com três
  alvos e duas entregas, e o processador que recebe a parada contando uma vez.
- Documentação: `docs/audits/2026-11-01-halt-ipi-and-fatal.md`,
  `docs/PROJECT_STATUS.{md,json}` (`smp` 73% → 76%, `kernel_cpu_interrupts`
  73% → 75%), `README.md`, `docs/ai/context-pack.md` e o item 6 do K2 no roadmap.

### Added (2026-11-01) — um relógio por processador, e um contador que sabe de quem é

- **O defeito**: o handler do vetor 64 perguntava `timer.drivesScheduler(.apic)`,
  uma política **por sistema**. Como o 8254 é o dono, um tick da APIC nunca era o
  dono — então, numa AP (que só tem o próprio timer local), a interrupção era
  reconhecida e **não preemptava**, sem nada no log dizendo isso.
- **As duas perguntas separadas**: `timer.drivesScheduler(source)` continua
  respondendo pelo **relógio da máquina**, e `timer.drivesSchedulerOn(cpu, source)`
  responde pelo **relógio daquela CPU**.
- **Um papel por CPU**: `timer.armCpuClock(cpu, role)` com `system` (o BSP conta a
  fonte que `selectTickSource` escolheu) e `local` (a AP conta o próprio timer e
  **nunca** move o relógio da máquina). Armar duas vezes com o mesmo papel não
  muda nada; armar com papel diferente é recusado — contar os dois relógios é o
  defeito C.6 da auditoria em outro lugar.
- **O contador que torna o erro visível**: um tick que chega num processador cujo
  relógio não é o que disparou é `timer.ignoredTicks()`, impresso no boot.
- **A AP arma o próprio relógio**: depois do gancho que lhe dá uma tarefa, ela faz
  `apic.enable()`, `apic.setTpr(0)`, `timer.armCpuClock(cpu, .local)` e
  `timer.armLocalApicTimer()`, que usa a frequência de barramento que o BSP mediu
  (`calibrated_bus_frequency`) e **recusa** quando não há medida em vez de
  adivinhar o divisor.
- **Quatro testes de host** (841 no total, `arch-tests` 172): a armação
  idempotente e o papel contraditório recusado; o relógio do sistema contado só
  por quem o possui (o tick da APIC no BSP é ignorado); a AP contando os próprios
  ticks sem mover o tempo da máquina; e o processador que ninguém armou.
- **Linhas de boot**: `[KNK] timer: cpu=N owns the clock of the system`,
  `[KNK] timer: N ignored ticks` e `[KNK] smp: cpu=N clock armed (...)`.
- Documentação: `docs/audits/2026-11-01-per-cpu-clock.md`,
  `docs/PROJECT_STATUS.{md,json}` (`smp` 68% → 73%, `kernel_cpu_interrupts`
  70% → 73%), `README.md`, `docs/ai/context-pack.md` e a anotação do item 6 do
  K2 no roadmap.

### Added (2026-11-01) — a TLB shootdown, so a page that leaves the tables leaves every TLB

- **O vetor e o aviso**: `apic.shootdown_vector` (66) e `apic.sendShootdown`, com
  stub em `interrupt.s`, porta no IDT e um handler que encerra a interrupcao e
  responde.
- **A caixa de correio** (`kernel/arch/x86_64/tlb.zig`): a IPI carrega um vetor e
  nao um endereco, entao a pagina viaja por memoria. Cada pedido tem uma geracao:
  um aviso reentregue e `duplicate`, um reconhecimento atrasado e `stale`, e o
  desconto e um compare-and-swap que nunca deixa a contagem de respostas passar
  por baixo de zero — sem isso um unico atraso transformaria o pendente em
  4 294 967 295 e o pedido seguinte nunca fecharia.
- **`smp.shootdown`** recusa com motivo (`no_targets`, `no_apic`), devolve
  `.complete` quando todos responderam e `.timeout` quando alguem nao respondeu,
  contando o tempo perdido em vez de esconde-lo. O handler roda no processador
  que tem a traducao velha, invalida (`invlpg`, ou CR3 recarregado para o escopo
  `all`) e so entao reconhece.
- **O gancho das tabelas de pagina**: `paging.installRemoteFlush` instala
  `smp.flushRemotePage` no boot, e as tres saidas de pagina (`unmapKernelPage` e
  os dois caminhos de `unmapUserPageIn`) chamam o gancho depois do `invlpg`
  local. O `paging.zig` continua sem importar o APIC, e os testes das tabelas
  rodam sem controlador.
- **`cpu.flushTlb`** e `kynox_flush_tlb` em `cpu.s`: a unica forma de esvaziar o
  TLB inteiro e recarregar o registrador da base das tabelas.
- **Nove testes de host** (837 no total, `arch-tests` 168): cinco em `tlb.zig`
  (o pedido que so termina com todas as respostas, o aviso repetido, o pedido
  abandonado e o atrasado, a geracao nova contra o reconhecimento velho, a caixa
  vazia) e quatro em `smp.zig` (a maquina com um processador, a recusa sem
  controlador, o aviso espuro e o handler que invalida e reconhece uma vez).
- **Linha de boot**: `[KNK] tlb: N shootdowns, N flushes served, N timeouts`.
- Documentacao: `docs/audits/2026-11-01-tlb-shootdown.md`,
  `docs/PROJECT_STATUS.{md,json}` (`smp` 60% → 68%, `virtual_memory` 50% → 56%,
  `kernel_cpu_interrupts` 66% → 70%), `README.md`,
  `docs/architecture/memory-management.md` (o invariante M4),
  `docs/ai/context-pack.md` e a anotacao do item 6 do K2 no roadmap.

### Fixed (2026-11-01) — the version of the image builder goes to stdout

- `kynox-fsimg --version` printed the banner with `std.debug.print`, which
  writes to **stderr**: `kynox-fsimg --version | grep ...` saw an empty stream,
  and the CI step that checks the version of the generated artifact failed on
  the last commit of the branch while the build and 828 tests passed. The
  banner is data, not a diagnostic, and now goes through a stdout writer with
  an explicit flush. The exact CI snippet was re-run here and exits 0.

### Added (2026-11-01) — a reschedule IPI, so another CPU can hand over a task

- **The IPI**: `apic.reschedule_vector` (65), `apic.sendReschedule`, the stub of
  the vector in `interrupt.s`, its gate, and a handler that ends the interrupt
  and asks the scheduler. It is the answer to the gap of the previous round — a
  queue belongs to one CPU and the only clock of the system reaches one
  processor.
- **A reschedule is not a tick**: `decideNext(forced)` — the IPI handler
  (`scheduler.rescheduleCurrent`) decides without counting a tick and without
  charging the slice, so a timeout never depends on another CPU and a quantum
  never shrinks because somebody asked a question.
- **`migrateTo(task, cpu)`**: the way a task reaches a processor other than the
  one that created it, refusing a running task, a terminated one, an id above
  `max_cpus` and a move to the current owner. At boot, `distributeWorkToAps()`
  migrates the second worker to the first online AP, and says why when no AP is
  online.
- **`smp.reschedule`** returns why it refused: `.same_cpu`, `.unknown_cpu`,
  `.not_online`, `.no_apic`, or `.sent` (counted); every refusal happens before
  the controller is written.
- **A wake that lands on another CPU** now queues the task on the CPU that owns
  it and requests a reschedule of that CPU, instead of silently migrating the
  task to the queue of the waker.
- **A counter defect fixed**: `startAps` and `registerCpu` both incremented the
  online count, so two processors were reported as three. The AP counts itself
  once, and a host test asserts it.
- **Seven new host tests** (828 in total, `task-tests` 72, `arch-tests` 159): the
  reschedule that switches without moving the quantum or the clock, the
  reschedule with nothing to run, the migration with its four refusals, the wake
  of a task of another CPU, one count per registered AP, the refusals of
  `smp.reschedule` and the first online AP.
- Documentation: `docs/audits/2026-11-01-reschedule-ipi.md`,
  `docs/PROJECT_STATUS.{md,json}` (scheduler 79% → 83%, SMP 52% → 60%), the
  counts, `README.md`, `docs/ai/context-pack.md`,
  `docs/architecture/execution-model.md` and the K2 annotation of the roadmap.

### Added (2026-11-01) — every task names the CPU that owns it

- **`Task.cpu`**: the ownership the scheduler only pretended to have. The choice
  of a CPU used to scan **every** ready task in the pool, so a second processor
  would have taken a task of the BSP — its idle task included — and the two would
  have shared one stack and one saved context. `describeQueue` now skips every
  task of another CPU, and `enqueueReady` records the CPU that queues a task, so
  ownership travels with the queueing.
- **One idle task per CPU** (`ensureIdle(cpu)`), each with its own 8 KiB user
  stack and 8 KiB kernel stack, clamped above `max_cpus` before anything is
  created.
- **`adoptKernelTask(cpu, stack_top, stack)`**: an AP arrives from the trampoline
  in ring 0 with no task, and `prepareNext` starts with `current[cpu] orelse
  return false`. The processor now gets a kernel task of its own (state
  `running`, its own stack, not queued), so a switch has a context to save.
  `smp.installCpuEntryHook` is how it does that without `smp.zig` importing the
  scheduler (which imports `smp`), and the boot prints
  `[KNK] smp: cpu=N entered the scheduler as task X, idle task Y` plus
  `[KNK] tasks: N CPU(s) entered the scheduler`.
- **Six new host tests** (821 in total, `task-tests` 68, `arch-tests` 156): a
  task of another CPU is never chosen, the idle task of a CPU is not the last
  resort of another, one idle task per CPU and idempotent per CPU, the task an AP
  adopts, ownership following `enqueueReady`, and the stack accessor of a CPU.
- **Correction**: `docs/audits/2026-11-01-idle-task-and-per-cpu-tss.md` claimed
  that every task of the kernel is ring 3. It is not: `spawn` creates ring 0
  kernel threads. The record carries the correction.
- Documentation: `docs/audits/2026-11-01-cpu-affinity.md`,
  `docs/PROJECT_STATUS.{md,json}` (scheduler 74% → 79%, SMP 44% → 52%), the
  counts, `README.md`, `docs/ai/context-pack.md`,
  `docs/architecture/execution-model.md` and the K3 annotations.

### Added (2026-11-01) — the trampoline of the APs is published below 1 MiB

- **`kernel/arch/x86_64/ap_trampoline.zig`**: the block of `ap_trampoline.s` as
  data. The offsets of the fields come from the symbols the assembly exports
  (`kernelLayout()`), `install` copies the block into the low page and writes
  what is the same for every AP (GDT base, far pointer, CR3, EFER bits, entry),
  and `arm` writes one AP (stack, CPU number) clearing `ready` first and writing
  it **last**. Every refusal has its own error: field outside the block, block
  larger than a page, placement beyond the reach of a startup IPI, destination
  too small, source that is not the block, value that does not fit in a 32-bit
  field.
- **`smp.prepareTrampoline(address, cr3, efer_bits)`** is the caller the
  `ap_trampoline.s` never had, and `installApTrampoline()` at boot does the three
  checks that make it safe: the page is usable RAM in the firmware map, it is
  mapped by identity in the kernel tables, and the copy was validated. A refusal
  is a boot line, not a silent "no AP".
- **The AP sets the EFER bits of the BSP** (`LME` and, when the kernel enabled
  it, `NXE`) before it loads the kernel CR3: an NX entry with `NXE` clear is a
  reserved bit, and the general protection fault would happen inside the
  trampoline, where there is no IDT — a triple fault with no message.
- **One numbering for the CPUs**: the stack, the CPU number passed in RDI and the
  table index are the same number (the MADT index), instead of `cpu_id - 1`, which
  only held when the BSP was entry 0. The AP waits with `sti; hlt` instead of a
  bare `hlt`, which froze it for ever with interrupts disabled.
- **Nine new host tests** (815 in total, `arch-tests` 155): the vector and its
  page, refused placements, the copy with every field and `ready` cleared,
  arming two APs in a row, refused layouts and truncated 32-bit values, the
  unpublished trampoline, an announcement without a copy, and one stack per
  logical CPU.
- Documentation: `docs/audits/2026-11-01-ap-trampoline.md`,
  `docs/PROJECT_STATUS.{md,json}` (`smp` 30% → 44%, the measured counts, `K-01`),
  `README.md`, `docs/ai/context-pack.md`, the roadmap annotations of K0/K2.

### Added (2026-11-01) — a segment per processor and an idle task that halts

- **Audit defect 2 closed in code: one TSS per CPU.** `segment.zig` had one
  `TaskStateSegment`, one GDT table and one `GdtPointer`; it now has eight of
  each (with eight 16 KiB double-fault stacks), `tssFor(cpu)` clamps instead of
  indexing outside the table, `installForCpu(cpu, stack_top)` writes `rsp0` and
  `ist1`, builds the table, loads the GDT and reloads the data and code
  segments, and `kynox_ap_entry` calls it before an AP enters its loop. The
  scheduler writes `rsp0` through `segment.tssFor(smp.cpuId())`, and the boot log
  states the shape (`[KNK] segments: 8 task state segments, …`).
- **An idle task, and the policy that makes it the last resort.**
  `Scheduler.ensureIdle()` creates it once — a ring 3 task whose body halts the
  processor with `sti; hlt` — and `Statistics.idle` reports its id at boot. The
  policy gained `Entry.idle`: the choice returns the smallest-runtime **real**
  task whenever one is eligible, whatever the runtime of the idle task is, so an
  idle task can never displace a task that could run. `policy.idleVruntime` is
  where its accounting starts.
- **`cpu.waitForInterrupt()`**: `sti; hlt` as one instruction pair, because `hlt`
  with interrupts disabled never returns and `sti` only takes effect after the
  next instruction, which closes the window between the two.
- **Six new host tests** (806 in total, task 63, arch 146): the `rsp0` of one
  CPU does not touch the other, the descriptor of a CPU parses back to the base
  of its own segment, the idle task loses to any real task, two idle tasks are
  decided by the ring, `ensureIdle` is idempotent over the real queue, and a
  blocking call on a queue whose only candidate is the idle task succeeds and
  switches to it.
- Documentation: `docs/audits/2026-11-01-idle-task-and-per-cpu-tss.md` (the
  record), `docs/PROJECT_STATUS.{md,json}` (scheduler 68% → 74%, CPU/interrupts
  60% → 66%, the measured counts, `K-01`), `README.md`,
  `docs/architecture/execution-model.md` and `docs/ai/context-pack.md`.

### Added (2026-11-01) — the scheduler has a state lock with per-CPU ownership

- **`kernel/task/lock.zig`.** The audit's defect 1 was "no lock at all" over state
  that interrupt context and thread context both write. A plain spinlock would
  have deadlocked, because the scheduler calls itself inside one decision
  (`tick → prepareNext → expiry → wake → enqueue`): the new lock knows which CPU
  holds it and counts the nested acquisitions instead of spinning. It also counts
  contentions, wait iterations and refused releases, and those four numbers are
  reported at boot.
- **Every entry point takes it** — `tick`, `prepareNext`, `spawn`, `spawnUser`,
  `blockCurrent`, `blockCurrentForInput`, `killCurrent`, `terminateCurrent`,
  `wakeTask`, `enqueueReady`, `dequeueReady`, `init` — and every path releases it;
  a test asserts that after `tick`, `spawn`, `wakeTask` and `terminateCurrent` the
  lock is free and no release was refused. `statisticsOf` is the documented
  exception: it reads without the lock, because a diagnostic is worth more than a
  deadlock.
- **`blockCurrentOn`**: the generic blocking primitive over any wait queue, with
  the deadline written before the node is queued and the wait undone when there
  is nobody to switch to. It is what a mutex needs, and the new end-to-end test
  drives the whole chain: the holder takes the mutex, the waiter blocks on
  `mutex.waiters`, the release transfers the ownership, `wakeTask` makes the
  waiter ready, and the waiter releases.
- Measured: **800 tests in 52/52 steps** (`task-tests` 59, six of them for the
  lock, one of those a four-thread contention test), `zig build` writing the
  image, `docs-check` green. No runtime evidence: no AP has ever run, so the lock
  is never contended in the kernel.

### Added (2026-11-01) — the channel waits in the shared queue, and the documentation has an index for agents

- **The wait queue has its first caller in the kernel.** `kernel/ipc/channel.zig`
  keeps a fixed array of registered waiters and orders them in
  `task/wait.zig`: delivery is FIFO (it used to follow the order of the storage
  array, which is not the order of arrival), the expiry writes the result
  through the new `WaitQueue.expireWith` hook **before** it wakes the task, and
  a delivered or expired waiter releases its slot. 4 new tests, 8 in total.
- **`docs/ai/` is the entry point for an agent.** `docs/ai/README.md` gives the
  reading order, the authority of each document and the hard rules;
  `docs/ai/context-pack.md` is the state of the tree in one page;
  `docs/ai/doc-index.json` is the generated map of all **62** documents with
  `kind`, `authority`, date, summary and word count. `llms.txt` at the root is
  the short manifest.
- **The index is enforced, not decorative.**
  `tools/scripts/gen-doc-index.py` holds the classification table and
  `--check` fails when a Markdown file is not classified, when an entry points
  at a file that does not exist, or when the index on disk differs from the
  table. It runs inside `zig build test` and inside `docs-check`, and
  `docs-conformance-tests` parses the index to assert the authorities, the
  reading order and that the status files are indexed as `current`.
- Measured: **788 tests in 52/52 steps** (task 47, ipc 9, docs-conformance 24),
  `zig build` writing the image, `docs-check` resolving every link and every
  classification. No runtime evidence: no QEMU, no OVMF.

### Added (2026-11-01) — the task subsystem: pure policy, wait queue, mutex

- **The scheduling policy left the scheduler.** `kernel/task/policy.zig` holds
  the decisions as pure functions over a flat description of the queue
  (`pickNext`, `shouldPreempt`, `quantumFor`, `budgetFor`, `deadlineFor`,
  `minVruntime`), and `scheduler.zig` keeps the state, the counters and the
  mechanism. It is step 2 of K3. 12 tests, including a property test over 200
  random queues against a reference implementation.
- **A wait queue that cannot lose a wakeup.** `kernel/task/wait.zig` was a
  42-line stub whose `dequeueWaiter` returned a field that nothing set; it is now
  a FIFO queue of caller-owned nodes with a deadline per wait, a remembered wake
  for the producer that runs first (`AddResult.already_woken`), a detach
  primitive for the direct handoff, and separate counters for a wake, a
  cancellation and a timeout. 11 tests, including a 500-operation invariant run.
- **A mutex with an owner.** `kernel/task/mutex.zig`: recursion up to 255, a
  queue of waiters, and a release that **transfers the ownership before it wakes
  the waiter**, so a third task cannot take the mutex in the interval. 10 tests,
  one of which asserts the ownership from inside the wake callback.
- **Deleted**: `kernel/task/runqueue.zig` (a stub whose dequeue did not shift and
  which nothing imported; the scheduler's own per-CPU `ready_queue` is the real
  one) and `tests/wait_lifecycle_regression.zig` (structural assertions, one of
  them now false, reachable from no target). Unreachable files: seven → six.
- Measured: **781 tests in 51/51 steps** (`task-tests` 46, `ipc-tests` filtered to
  its own channel tests so the shared modules are not counted twice), with
  `zig build` writing the image and no runtime evidence. The mutex and the queue
  have **no caller in the kernel yet**, and the scheduler still has no lock.

### Added (2026-11-01) — the scheduler policy is tested on the host

- **`scheduler-tests`, 12 tests.** The scheduling policy of
  `kernel/task/scheduler.zig` was executed by none of the 736 tests. The new
  root `kernel/task_root.zig` (next to `host_root.zig`) defines the four
  symbols that `arch/x86_64/task.s` provides for the real switch, so the policy
  — the FIFO ready queue, the full-queue refusal, the EEVDF choice by virtual
  runtime, the skip of blocked/terminated tasks and of threads of an
  `exiting`/`reaped` process, the stack-size refusal, the inherited start, the
  weight accounting, the pool limit, the tick and the blocked task — runs on
  the host. The artifact runs with a test filter so the architecture tests it
  imports are not counted twice.
- **Three preemption defects closed, found by those tests.** A tick used to
  switch to the next ready task whatever the quantum, so the slice decided
  nothing; the entering task did not get a new quantum, so a task was
  time-sliced exactly once in its life; and a preemption that found no other
  ready task left the running task marked `ready` with a zero quantum. The
  switch now happens at the end of the quantum (or as soon as the task
  blocks), the quantum is refilled from the slice, and the fallback restores
  the current task. Measured: **748 tests in 51/51 steps**
  (`scheduler-tests` 12), with `zig build` writing the image and no runtime
  evidence — no QEMU and no OVMF in this environment.

### Fixed (2026-11-01) — host-verified, not runtime-verified

- **The host suite was not running the architecture tests.** `fpu.zig` used
  unnamed inline-assembly operands and `paging.zig` imported a file outside its
  module path, so `arch-tests` did not compile and paging, ACPI, SMP and PCI
  tests were missing from the suite that reported 716 tests. After the fix the
  measured total was **736 tests in 49/49 steps** (`arch-tests` 144); the
  scheduler tests of the same day take it to 748.
- **Unmap now returns the frame it owns.** A software ownership bit
  (`paging.Flags.owned`) records the frames the space obtained from the manager;
  `takeOwnership` is applied when an image is fully materialised, and
  `unmapUserPageIn` releases only those frames. A borrowed page stays allocated,
  and without a release callback an owned entry is preserved with
  `error.ReleaseUnavailable` instead of being lost.
- **Address spaces are destroyed and their slots reused.**
  `destroyAddressSpaceReal` releases the frames, clears the private chain,
  forgets the active space and frees the slot; `createAddressSpace` reuses a free
  slot with a new generation, and `spaceByIdentity(id, generation)` refuses a
  stale identity. `spaces_created` and `liveSpaceCount` expose the state.
- **Capabilities have a lifecycle.** `capability.destroy`, `destroySubject` and
  `releaseProcess` free table entries and take the handle from every holder;
  `process.reapFull` releases the set of a reaped process and destroys the
  capabilities that named it. The no-op `security.revokeCapabilities` stub is
  removed. The 16-entry table is now a pool instead of a lifetime limit.
- **Interrupt lines have owners.** New `kernel/arch/x86_64/interrupt_registry.zig`
  (one owner per line, refusal of a second registration, per-line counters,
  unhandled-line accounting) with host tests. `interrupt.zig` dispatches through
  it, and the kernel registers the 8254 and PS/2 lines before interrupts are
  enabled. **The dispatch path itself has not run.**
- **One tick source.** `timer.TickSource` and `selectTickSource` make one clock
  the owner of the tick and of the preemption; the other is acknowledged and
  ignored. The local APIC timer is still calibrated and is now left disarmed
  while the 8254 owns the tick, so intervals are no longer counted twice.
- **`net_transmit` fails explicitly** with `error.NotImplemented` instead of
  reporting a transmission that never happened, and `virtio_net.zig` joined the
  architecture test root (its ten header-layout tests had never been compiled).
- **Dead files removed:** `kernel/arch/x86_64/elf_compat.zig`,
  `kernel/fs/dir_entry.zig`, `kernel/fs/test_ramfs_runner.zig` (which did not
  compile and had two tests in no test root) and the unused
  `paging.window_pages`.
- **Two module cycles closed:** `apic.zig` imported `timer.zig` without using a
  symbol; the import is gone.
- Documentation corrected in the same change:
  `docs/PROJECT_STATUS.md`/`.json` (new snapshot, measured counts, closed and
  open defects), `README.md`, `docs/architecture/memory-management.md`, and a new
  implementation record `docs/audits/2026-11-01-kernel-core-fixes.md`.
  `virtual_memory` moved from 45% to 50%; no other percentage moved.

### Added

- `docs/strategy/market-landscape.md` — market structure, nine technology
  deep dives (desktop, window management, rendering, GPU APIs, driver models,
  gaming, security, updates, tooling), ranked opportunities, risk register and
  fifteen dated sources. Planning document: it claims no feature.
- `docs/architecture/platform-architecture.md` — layer map with a "today"
  column, a sixteen-row kernel/user-mode table, twenty subsystem contracts
  (responsibility, interfaces, dependencies, privilege bounds, concurrency,
  memory, failure, security, performance criteria, current state, next step),
  dependency graph, concurrency model, failure ladder and unmeasured budgets.
- `docs/architecture/graphics-platform.md` — Display System (KDS), GPU driver
  model with honest vendor tiers, graphics core (KGC), native API (KGA),
  renderer (KGR), compositor and window system (KWM), tools (KGT), security
  and performance model, and graphics steps G0–G9.
- `docs/architecture/application-ecosystem.md` — KEX v2 layout and manifest,
  loader pipeline, SDK layers, linking model, KPK packaging and signing,
  installation layout, atomic updates and rollback, portal sandbox, and the
  compatibility contract for KLC/KWC.
- `docs/architecture/security-architecture.md` — claimed-today table, threat
  model, boot chain, hardening, capability proof obligations, device/IOMMU
  rules, sandbox, supply chain, audit and recovery, per-property evidence and
  explicit non-guarantees.
- `docs/architecture/graphics-compatibility.md` — KGA formalised as a contract
  (objects, commands, synchronisation, memory, pipelines, shaders, versioning,
  capability tiers, public/internal split), plus KGL (OpenGL) and KVK (Vulkan)
  as front-ends over one shared execution core (KGX). Includes semantic-gap
  tables, the Linux/Windows graphics path matrix, a security table and a
  performance-claim policy that forbids "zero overhead" language.
- `docs/architecture/linux-compatibility.md` — KLC: the seven separated
  contracts, ELF64 loading and initial process state, the three syscall
  translation options and the chosen staged hybrid, signals, futex/TLS,
  dynamic linking, KLIBC/KLD/KVD policy, namespace and permission model,
  security threats, support matrix and phases C-L0…C-L5.
- `docs/architecture/windows-compatibility.md` — KWC: why the ntdll boundary
  differs from Linux's trap boundary, PE32+ loading, TEB/PEB, the KOB handle
  model, kernel32/CRT, SEH/unwind, registry virtualisation, user32/GDI, COM,
  Winsock, the D3D evaluation and explicit non-guarantees.
- `docs/roadmap/COMPATIBILITY_ROADMAP.md` — phases C0–C11 with objective,
  scope, dependencies, components, completion criteria, conformance and
  performance tests, risks, evidence and promotion rules; a critical review
  that reorders the proposed sequence (KWM before KGL/KVK, KLC/KWC in
  parallel rather than last).
- `docs/architecture/platform-architecture.md` §4.19–4.20 — compatibility
  personalities (KLC/KWC) and graphics front-ends (KGL/KVK) contracts, plus
  their rows in §4.0 and §10 and the dependency-graph entry.
- `docs/architecture/application-ecosystem.md` §8, `security-architecture.md`
  §8.1 and `PRODUCT_ROADMAP.md` S15 integrated with the new layers; no
  maturity percentage changed and no compatibility claim added.
- `docs/decisions/0008` shared graphics core, `0009` SPIR-V ingestion,
  `0010` compatibility execution model — all accepted for planning with
  reversal criteria.
- `docs/strategy/market-landscape.md` sources S16–S26 (Vulkan 1.4.365 spec and
  SDK, OpenGL 4.6, System V AMD64 psABI, PE format, x64 ABI, Linux ABI
  stability, futex) and extended planning-document inventory.
- `docs/architecture/user-experiences.md` — five profiles (home, gaming,
  development, enterprise, professional) with numbered, measurable
  requirements and the rule that a profile is policy, never a separate ABI,
  package format or graphics stack.
- `docs/architecture/platform-architecture.md` §4.0 — public versus internal
  interface table for all eighteen subsystems; §4.17 updates/recovery and
  §4.18 virtualisation/enterprise contracts.
- `docs/roadmap/PRODUCT_ROADMAP.md` — stages S0–S15 ordered by real
  dependencies, each with scope, prerequisites, interfaces, deliverables,
  objective completion criteria, tests, risks, external dependencies and
  acceptance; the P/F/E/H evidence ladder separates prototype from hardware
  validation.
- `docs/decisions/0004…0007` — graphics stack split, native graphics API,
  user-space compositor, and packaging/sandbox/updates. Marked **accepted for
  planning**; none is implemented and each carries reversal criteria.
- `docs_conformance.zig` — `docs-conformance-tests`: asserts the required
  sections of the planning documents, their dated sources, their presence in
  `docs/PROJECT_STATUS.json`, the ADR index entries and the roadmap ladder. It
  asserts structure only, never that a planned feature exists.
- `docs/PROJECT_STATUS.json` — new `planning_documents` inventory; no
  percentage was changed.
- `docs/audits/2026-10-31-kernel-core-audit.md` — kernel and core systems
  audit of the tree at `343e9fb`: per-item classification (`NOT_STARTED` …
  `VALIDATED`) for areas A–G with files, existing and missing features,
  dependencies, bugs, risks, test coverage and evidence; the test-coverage
  truth (no test covers the scheduler, interrupts, syscall dispatch, PS/2 or
  address-space teardown); fifteen ranked architecture defects; and a
  documentation-versus-code review that changes no percentage. This is an
  audit record, not a plan.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md` — fourteen stages K0–K13
  ordered by the dependency graph (boot/arch, memory, interrupts and SMP,
  synchronisation and scheduler, processes, security, syscalls and IPC,
  drivers, DMA, storage, VFS, console, time and power, diagnostics); each has
  objective, initial state, files, dependencies, required work, completion
  criteria, unit/integration/stress tests, QEMU and hardware validation,
  risks and P/F/E/H promotion; plus the genuine parallelism pairs, the
  validation-layer ladder and the environment blockers. No stage started.
- `docs/architecture/kernel-internals.md` — target layering, module contract
  table, global-state policy, error model, initialisation phases, proposed
  directory changes, the refactors that are justified by the audit and the
  ones explicitly rejected, and the kernel coding standards.
- `docs/architecture/memory-management.md` — frames, address spaces as
  objects, regions, page-fault policy, heap locking, the DMA interface and
  eight memory invariants with the test tier that checks each.
- `docs/architecture/execution-model.md` — process and thread objects,
  lifecycle, the policy/mechanism split, wait queues, mutex and rwlock, time
  and the user/kernel transition contract.
- `docs/architecture/device-driver-model.md` — device, driver and resource
  objects, the interrupt registration API, MSI programming, DMA ownership,
  class interfaces defined by their consumers, containment and the test tier
  each driver must reach.
- `docs_conformance.zig` — seven tests (15 → 22) that keep the kernel
  roadmap's fourteen stages and evidence ladder, the audit's classification
  vocabulary, the memory invariants, the process/thread split, the driver
  model's interrupt registry, and the planning status of the new documents
  from drifting. `docs-conformance-tests` now also asserts that the six new
  paths are in `docs/PROJECT_STATUS.json` (`planning_documents` 11 → 17).
- `docs/PROJECT_STATUS.md` / `.json` — the six documents registered in the
  inventory; the validation record updated to 716 host tests; **no maturity
  percentage was changed**.

### Added (earlier)

- `VERSION` — root file with the technical version (`0.1.0-alpha.1`), the only
  writable source of it.
- `docs/VERSIONING.md` — normative identity and versioning policy: public and
  technical forms, single source, generation resolution, SemVer rules, the five
  independent version lines, tags and the guards.
- `docs/roadmap/ERAS.md` — normative chart of generations (`0 Kynox One` …
  `14 Kynox Cosmos`), rules for opening an era and how to add one.
- `boot_markers_conformance.zig` — `boot-markers-conformance-tests`: every
  literal serial marker asserted by `tests/integration/boot-qemu.sh` must still
  be printed by a source. Verified by mutation (renaming `[KNK] handoff ok`
  fails the test). This guard caught a real regression: the kernel banner had
  stopped printing `[KNK] Kynox Nucleus Kernel`.
- `docs/audits/2026-10-31-audit.md` — full audit: executed build/test evidence,
  findings P1–P4 with file/line evidence, `v0.1.0-alpha.1` criteria assessment
  and a prioritized incremental plan.
- `docs/specs/boot-handoff-spec.md` — normative KNB → KNK handoff contract v1,
  derived from `shared/handoff.zig` and the loader/kernel call sites.
- `docs/specs/syscall-abi.md` — normative native syscall ABI (calling
  convention, frame layout, 22 syscalls, reserved number 12, validation rules,
  25 error codes, versioning policy).
- `docs/BUILD.md` — build/validation reference: toolchain acquisition, build and
  test commands, QEMU/OVMF prerequisites, and how to record results.
- `CHANGELOG.md` (this file).
- `docs/releases/0.1.0-alpha.1.md` — release-notes **draft** with the gate
  checklist; the tag does not exist.
- `version.zig` — single source of the system version (from `VERSION`),
  `build.zig.zon` mirror and `version-tests` artifact.
- `docs/VERSIONING.md` — identity, system version vs generation vs ABI revision
  vs binary-format vs protocol versions, channels and release procedure.
- `shared/syscall_abi.zig` — normative native ABI: revision 1, call numbers,
  limits, privilege values, error codes, capability kinds and rights.
- `abi_conformance.zig` — `abi-conformance-tests` artifact: fails when the
  contract, kernel dispatch, SDK and `docs/specs/syscall-abi.md` diverge.
- `docs/decisions/` — ADR register and three records: probes out of
  `kernel/main.zig` (0001), a single VirtIO transport owned by KVDI (0002), and
  the fate of the legacy `virtio_blk.zig` stub (0003). All three record a
  decision; none of them changes code.
- `docs/validation/qemu.md` — QEMU procedure (prerequisites, exact VM
  configuration, what a run must record) and the dated table of attempts, all
  marked not executed for the missing firmware and emulator.
- `docs/specs/acpi-platform.md` — RSDP/XSDT/RSDT/MADT discovery, validation,
  fallback lines and the explicit list of what is not implemented.
- ACPI discovery in the boot path: `acpi.discoverMadt` with an injected table
  source, `Madt.lapicBase()`/`IoApic.isValid()` validation, `apic.setBase`/
  `resetBase`, and `discoverAcpi` in `kernel/main.zig` (before CR3 is replaced).
- `acpi.zig` is now reachable from the `arch-tests` root: its tests had never
  executed before this change.

- `kernel/arch/x86_64/ioapic.zig` — I/O APIC register access and redirection
  entries: MMIO offsets (select `0x00`, window `0x10`), version decode (version
  in bits 0..7, entry count minus one in bits 16..23), 64-bit entry
  encode/decode, `DeliveryMode`/`Polarity`/`Trigger`, `Controller` with
  `init`/`ownsGsi`/`readEntry`/`program`/`mask`/`unmask`/`maskAll`/`allMasked`
  and a small spinlock for the select/window pair. Eight host tests.
- `acpi.IsaRoute` and `acpi.isaRoute(irq, overrides)` — effective GSI,
  polarity and trigger of an ISA line, with the ISA bus default (high level,
  edge) and the MADT interrupt-source-override flags decoded per bits [1:0] and
  [3:2] (3 = reserved → conforming high/edge).
- I/O APIC programming in the boot path (`installIoApic`): maps the controller
  page, initialises it, masks every entry, programs the ISA lines in use
  (`32 + irq`, BSP destination) with the properties from `isaRoute`, and logs
  one line per route. Entries stay **masked**; delivery switches to the I/O
  APIC only with the new build option `-Dioapic-delivery=true`
  (`kynox_config.ioapic_delivery`, default `false`), which masks both 8259s
  before unmasking any entry.
- `timer.endOfInterrupt(vector)` and `timer.disablePic()` — the EOI target
  follows the delivery switch (local APIC when the I/O APIC delivers, 8259
  otherwise); masking the PIC is explicit and separate from the 8259 remap.
- `apic.sendInit(apic_id)` — INIT IPI, first message of the INIT-SIPI-SIPI
  sequence.
- SMP CPU table from the MADT: `smp.configureFromMadt` (enabled processors in
  table order, duplicates skipped, `max_cpus` cap), `apicIdFor`,
  `cpuIndexForApicId`, `bspCpuIndex`, `discoveredCpuCount`; `cpuId()` now
  translates the local APIC id through the table instead of assuming 0.
- `smp.publishTrampoline` and the startup gate: `startAps()` sends nothing when
  no AP was discovered or when the trampoline is not published below 1 MiB.
  When both hold, each AP receives INIT + two SIPIs and the BSP waits a bounded
  number of pauses for `online`; a silent AP is reported, never assumed online.
- `scripts/check-docs-links.py` and the build step `docs-check` (also part of
  `test`): every relative Markdown link must resolve in the tree.
- `scripts/provision-qemu.sh` — isolated, root-free provisioning of a static
  QEMU and OVMF into `.tools/` (ignored by Git); `--check` reports what is
  present. Blocked in this sandbox (see `docs/validation/qemu.md` §8).
- `.github/workflows/ci.yml` — build + host tests + documentation links, and a
  separate QEMU job that installs `qemu-system-x86`/`ovmf` and **fails
  explicitly** when it cannot, instead of reporting a green run that booted
  nothing. Not executed yet.

### Changed

- `probeVirtqueueLayout` (ADR-0002 step 2) now exercises
  `kvdi.virtqueue` instead of the legacy queue: the marker
  `[KNK] virtio: split queue layout ok` is unchanged, its numbers are the KVDI
  layout (`desc=0 avail=256 used=304 size=448`). `kernel/main.zig` no longer
  imports `arch/x86_64/virtio.zig`; the legacy module and `virtio_net.zig`
  remain for their last step (deletion), which is recorded as pending.
- `apic.zig` no longer leaves the register pointer `undefined` before `map`
  (undefined pointer arithmetic in `isMapped`); it points at the default base
  until mapped and `isMapped` reports an explicit flag. `sendIpi` mixed an enum
  with an integer in a bitwise or, which did not compile once instantiated —
  now explicit conversions.
- `smp.startAps()` no longer assumes sequential APIC ids (BSP = 0, APs = 1..n).
- `version.zig` now embeds `VERSION` instead of holding components, and resolves
  the official generation from the major: `display` is `Kynox One 0.1.0-alpha.1`,
  `generationFor`/`generationNameFor`/`generationOf`/`publicNameInto` reject
  majors without a name (`error.UnnamedGeneration`). Tests cover the chart,
  name uniqueness, arbitrary versions, the documents and the absence of
  literals in components.
- Boot and kernel banners print the public identity and the separate
  version/generation/tag/channel/ABI lines; the component marker is preserved
  (`[KNB] Kynox Native Boot - …`, `[KNK] Kynox Nucleus Kernel - …`).
- `docs/PROJECT_STATUS.md` / `docs/PROJECT_STATUS.json` — schema v2: per-subsystem
  `implemented`, `limitations`, `pending_work`, `tests` and `validation` fields;
  status vocabulary migrated to the mandated set
  (`not_started`, `scaffolding`, `in_progress`, `implemented`, `integrated`,
  `validated`, `blocked`); executed validation recorded. **Maturity percentages
  were not raised.**
- `README.md` — dated verification record (what was executed), toolchain
  acquisition note, links to the new audit and specs, corrected claims about
  built test applications.
- `sdk/README.md` — rewritten from the code: current modules, entry contract,
  usage, ABI reference and real validation state. Removed obsolete claims
  (unvalidated status, `feat/native-sdk` branch instructions, "Fedora" as the
  only validation host, ABI revision 9, "no new syscall numbers", F6 raster
  "not connected to the boot framebuffer").

- `kernel/arch/x86_64/syscall.zig`, `kernel/security/capability.zig`, `sdk/src/syscall.zig`,
  `sdk/src/root.zig`, `boot/uefi/main.zig`, `kernel/main.zig`, `tools/fatimg.zig`
  now derive their version constants, syscall numbers, error codes and
  capability values from the shared contract instead of private copies.
- `apic.apic_base` (fixed const) became `apic.default_base` plus a validated,
  runtime-selected base; `installSmp` maps the base actually in use.
- `build.zig.zon` version `0.1.0-dev.3` → `0.1.0-alpha.1`; loader and kernel
  banners print the system version, tag and ABI revision.
- `tests/integration/boot-qemu.sh` — an empty `OVMF_CODE`/`OVMF_VARS` pair is no
  longer printed as `:` in the diagnostic (setting only one of them is now an
  explicit error), and a missing `qemu-system-x86_64` is reported as such with
  exit code 3 instead of failing inside the VM launch.

### Fixed

- Dangling documentation references: `docs/specs/boot-handoff-spec.md` and
  `docs/specs/syscall-abi.md` are now real; the reference to a non-existent
  `docs/adr/ADR-F04-block-driver-proposta.md` in
  `kernel/arch/x86_64/virtio_blk.zig` was replaced by an honest statement of the
  pending work (ADR to live in `docs/decisions/`, per `strategy.md`).
- `.gitignore` — removed a stray Markdown fence that had been committed at the
  end of the file.
- `tools/fatimg.zig` module documentation — stated the image content it really
  writes (`/boot/KYNOXK.ELF`) instead of a file name the loader would not find
  (audit A-19).
- `docs/PROJECT_STATUS.md` — "multiple built test applications" corrected to the
  two applications the build actually embeds (`user/hello.zig`,
  `user/client.zig`).

### Validation performed

| Command | Result |
|---|---|
| `zig version` | `0.17.0` |
| `zig build` | success (14/14 steps); `kynox.img` 128 MiB, 32 731 clusters |
| `zig build test` | success — 716/716 tests, 49/49 steps (23 test artifacts, fresh cache, `docs-check` and `docs-conformance-tests` included) |
| `zig build docs-check` | success — every relative link resolves |
| `zig build -Dioapic-delivery=true` | success (compiles; **never booted**, so no delivery is claimed) |
| `zig build qemu-test` | not executed — exits 2, `no OVMF firmware found` (see `docs/validation/qemu.md`) |
| `zig build qemu-storage-test` | not executed — fails through the same dependency |
| `zig build qemu-interactive-test` | not executed — same missing firmware |
| `command -v qemu-system-x86_64` | absent; installing is impossible in this sandbox |

### Known limitations

See `docs/PROJECT_STATUS.md` §"Important limitations and corrections" and the
audit findings A-01 … A-18. The most important open items: runtime evidence at
all (QEMU/OVMF) — every I/O APIC and SMP claim above is host-tested only —,
delivery through the I/O APIC, AP bring-up (the trampoline is not published),
PCI GSI routing, and the remaining ADR steps (0001 reports/remaining probes,
0002 step 3, 0003). The kernel audit records the architectural causes behind
several of them: one global TSS (ring 3 on an AP is impossible), no TLB
shootdown, unmapping that never frees a frame, a scheduler with no lock and no
tests, no interrupt registration API, and a `virtio-net` transmit that returns
success while transmitting nothing.

## [0.1.0-alpha.1] — UNRELEASED (draft)

> This section is a **draft**. The tag `v0.1.0-alpha.1` does not exist, no date
> is assigned and no commit is recorded. It will be finalized only when the gate
> checklist in `docs/releases/0.1.0-alpha.1.md` is satisfied. Nothing here may be
> read as a released capability.

Work expected to be summarized at release time (already present in the tree,
first time documented):

- Native UEFI boot application (KNB) with the versioned KNB → KNK handoff.
- Freestanding x86_64 kernel (KNK) with GDT/TSS/IDT, exception stubs, timer,
  four-level paging with NX enforcement and per-process user windows.
- PMM, kernel heap, DMA window; ACPI/PCI parsers; LAPIC; early AP startup.
- Preemptive scheduler with context switching and task lifecycle.
- `syscall`/`iretq` entry path with 22 native calls, capability checks and
  user-pointer validation.
- IPC channels with blocking, bounded queues, timeouts; typed capabilities with
  delegation and revocation.
- ELF64 load planning/materialization, KEX container, KPK package codec.
- RamFS, KFSX namespace, KNV volume commit/recovery, block API.
- KVDI (Kynox Virtual Device Interface) transport and synchronous VirtIO Block
  read/write/flush over a PCI virtqueue.
- Rasterizer, compositor, window manager, damage tracking, PS/2 keyboard input
  and a boot-time desktop scene.
- Zig SDK, two native applications embedded in the image, host test suite
  (661 tests) and QEMU integration scripts.
- **Not included:** Linux compatibility (0%), Windows compatibility (0%),
  networking stack, GPU acceleration, ring-3 services/compositor, dynamic
  linking, journaled filesystem.

## Release history

No release has been published. `git tag` is empty and the history starts at a
single commit (`5c98311`, branch base).
