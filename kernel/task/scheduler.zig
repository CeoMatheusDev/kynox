//************************************************************************//
//  scheduler.zig                                                         //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                   //
//             https://github.com/CeoMatheusDev/Kynox                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 Kynox - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! The task fabric: tasks and the scheduler.
//!
//! A task is a context of execution: the registers that the architecture
//! does not save between calls and a stack. The scheduler is preemptive, the
//! timer of the kernel decides when a task leaves the processor.
//!
//! The policy is deliberately the simplest one that can be verified: the
//! tasks are visited in the order of their creation. Every design decision
//! that needs measurements, like the latency sensitive scheduling for
//! interactive applications, belongs to a later increment and has to be
//! justified with data.

const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("../arch/x86_64/cpu.zig");
const kynox = @import("kynox_shared");

const context = @import("context.zig");
const paging = @import("../arch/x86_64/paging.zig");
const segment = @import("../arch/x86_64/segment.zig");
const smp = @import("../arch/x86_64/smp.zig");
const channel = @import("../ipc/channel.zig");
const lock = @import("lock.zig");
const x86_cpu = @import("../arch/x86_64/cpu.zig");
const policy = @import("policy.zig");
const wait_queue = @import("wait.zig");
const process = @import("process.zig");

/// The context of a task.
pub const Context = context.Context;

/// The selector of the code segment of the kernel.
const kernel_code_selector: u64 = segment.selectors.kernel_code;

/// The selector of the data segment of the kernel.
const kernel_data_selector: u64 = segment.selectors.kernel_data;

/// The selector of the code segment of the user mode.
const user_code_selector: u64 = segment.selectors.user_code;

/// The selector of the data segment of the user mode.
const user_data_selector: u64 = segment.selectors.user_data;

/// The state of a task.
pub const State = enum {
    /// The task can be scheduled.
    ready,
    /// The task is running.
    running,
    /// The task is waiting for an event.
    ///
    /// The blocked task waits for a message, and the scheduler does not
    /// choose it until the message arrives.
    blocked,
    /// The task finished.
    terminated,
};

/// A task of the kernel.
pub const Task = struct {
    /// The identifier of the task, in the order of creation.
    id: u32 = 0,
    /// The saved context of the task.
    context: Context = .{},
    /// The stack of the task, the one where its own code runs.
    stack: []u8 = &.{},
    /// Stack canary: value stored at the lower boundary of the kernel stack.
    ///
    /// On every context switch, the canary is written to the stack and
    /// verified when the task resumes. A mismatch indicates a stack
    /// corruption (buffer overflow, stack smashing), and the kernel
    /// will terminate the offending task.
    stack_canary: u64 = 0,
    /// Address of the canary at the lower boundary of the kernel stack.
    stack_canary_address: u64 = 0,
    /// The stack of the kernel of the task, where the handlers run.
    ///
    /// A task has two stacks: the one of its own code, and the one of the
    /// kernel, which receives the frames of the interrupts and of the
    /// calls. The two are never the same memory, for two reasons: the
    /// frame of the interrupt is built on the stack of the kernel, and the
    /// frame of a task that runs in the user mode would otherwise live in
    /// a page that the user owns and can rewrite.
    kernel_rsp: u64 = 0,
    /// The address space of the task, when the task is a process.
    ///
    /// A null value means the space of the kernel, which is the space of
    /// the tasks of the kernel.
    space: ?*paging.AddressSpace = null,
    /// The process that owns this thread (null for kernel-only threads).
    process_ref: ?*process.Process = null,
    /// The next task in the list of the reaper.
    ///
    /// The link lives in the task, so that a task that ends never allocates to
    /// be collected, and the reaper has a single list to walk however the task
    /// ended (an ordinary exit or an exception of the user mode). A plain link
    /// and not a `wait_queue.Node`: nothing sleeps in this list and nobody is
    /// woken through it, so the node of the wait queue — with its wake routine
    /// and its remembered wake — would be machinery that never runs.
    reap_next: ?*Task = null,
    /// Whether the task is in the list of the reaper right now.
    ///
    /// It is what makes a second request from the same task a no-op, and what
    /// stops the collection of a task that already went back to the pool.
    reap_queued: bool = false,
    /// The state of the task.
    state: State = .ready,
    /// The code with which the task ended.
    exit_code: u64 = 0,
    /// The number of times the task was scheduled.
    schedules: u64 = 0,
    /// The priority of the task. Higher values mean higher priority.
    /// The scheduler chooses the ready task with the highest priority.
    priority: u8 = 0,
    /// The CPU that owns the task.
    ///
    /// The scheduler keeps one queue and one `current` per CPU, and this field
    /// is what ties a task to one of them. Before it existed, the choice on a
    /// CPU looked at **every** ready task in the pool: a second processor would
    /// have taken a task of the BSP — its idle task included — and the two CPUs
    /// would have shared a stack and a saved context. A task is created on the
    /// CPU that creates it, and `enqueueReady` records the CPU that queues it.
    cpu: u8 = 0,

    /// Whether the task is the idle task of its CPU.
    ///
    /// The idle task exists to be the last resort of the processor: it halts
    /// instead of returning to whatever an interrupt interrupted. The policy
    /// chooses it only when no other task can run, whatever its virtual runtime
    /// says.
    is_idle: bool = false,

    /// The time quantum of the task, in ticks of the scheduler timer.
    ///
    /// When the quantum expires, the task is preempted and returned to the
    /// ready queue, and the scheduler chooses the next task. A quantum of
    /// zero means that the task is not subject to time-slicing.
    quantum: u16 = 0,
    /// Peso da tarefa para o EEVDF (virtual runtime).
    ///
    /// Um peso maior significa mais tempo de CPU por tick. O valor padrao
    /// 1024 corresponde ao peso unitario (nice 0). O runtime virtual
    /// avanca em `1024 / weight` por tick.
    weight: u32 = 1024,
    /// Runtime virtual acumulado da tarefa (EEVDF).
    vruntime: i64 = 0,
    /// Prazo virtual da tarefa (EEVDF): o escalonador escolhe, entre as
    /// tarefas elegiveis, a que tem o menor prazo.
    deadline: i64 = 0,
    /// Fatia de tempo da tarefa, em ticks, usada para calcular o prazo.
    slice: u16 = 10,
};

/// Maximum number of tasks that the kernel supports.
pub const max_tasks = 32;

comptime {
    // The policy receives the queue as a fixed array on the stack, because the
    // choice runs from the timer interrupt and cannot allocate. A pool larger
    // than the array would silently hide tasks from the policy, so the size of
    // the pool may never pass the size of the description.
    if (max_tasks > policy.max_entries) {
        @compileError("scheduler.max_tasks is above policy.max_entries");
    }
    // The ownership table of the state lock names one CPU per entry, and the
    // scheduler keeps one `current[]` and one ready queue per CPU. The two
    // limits are the same number in two modules, and they may not drift.
    if (smp.max_cpus > lock.max_cpus) {
        @compileError("scheduler: smp.max_cpus is above lock.max_cpus");
    }
}

/// Summary of the state of the scheduler.
pub const Statistics = struct {
    /// Number of tasks that exist.
    tasks: u32 = 0,
    /// Number of tasks that are ready.
    ready: u32 = 0,
    /// Number of tasks that are blocked waiting for a message.
    blocked: u32 = 0,
    /// Number of ticks of the timer.
    ticks: u64 = 0,
    /// Number of switches between tasks.
    switches: u64 = 0,
    /// Number of times a task blocked waiting for a message.
    blocks: u64 = 0,
    /// Number of tasks that were killed by an exception.
    killed: u64 = 0,
    /// Total cost of the switches, in cycles.
    switch_cycles: u64 = 0,
    /// Cost of the last switch, in cycles.
    last_switch_cycles: u64 = 0,
    /// Smallest cost of a switch, in cycles.
    minimum_switch_cycles: u64 = 0,
    /// Acquisitions of the state lock that found it held by another CPU.
    lock_contentions: u64 = 0,
    /// Acquisitions of the state lock made by the CPU that already held it.
    lock_reentries: u64 = 0,
    /// The largest nesting of the state lock seen so far.
    lock_max_depth: u32 = 0,
    /// Releases of the state lock made by a CPU that did not hold it.
    lock_refused_releases: u64 = 0,
    /// Reschedules requested by a wake that landed on another CPU.
    ///
    /// A task that becomes ready on CPU 1 while CPU 0 runs the waker is useless
    /// to CPU 0: the queue that holds it belongs to CPU 1, and CPU 1 is asleep
    /// in `sti; hlt`. The waker therefore asks for an IPI, and this counter is
    /// how many times that happened.
    wake_reschedules: u64 = 0,
    /// Reschedules served by `rescheduleCurrent` (the IPI handler).
    reschedules: u64 = 0,
    /// Tasks whose slot went back to the pool because they ended.
    ///
    /// A task that terminates leaves its slot in the storage, and the slot is
    /// what bounds `max_tasks`. Without this counter the only sign of a leak
    /// would be the creation that returns null after 32 processes have run
    /// their whole life.
    reaped: u64 = 0,
    /// Tasks that ended and are waiting for a processor to collect them.
    ///
    /// A task cannot return a slot that belongs to the code it is running: it
    /// asks for the reaper and the reaper frees it in another context.
    pending_reap: u32 = 0,
    /// How many CPUs have a task of their own (`adoptKernelTask`).
    ///
    /// It is the number of processors that entered the scheduler, and not the
    /// number of processors that the MADT described: an AP that never answered
    /// a startup IPI is not one of them.
    entered_cpus: u8 = 0,
    /// The id of the idle task of this CPU, or -1 while it does not exist.
    ///
    /// The idle task is the last resort of the processor: it is what the
    /// scheduler returns when nothing else can run, and the only reason a
    /// blocking call can succeed on an otherwise empty queue.
    idle: i32 = -1,
};

/// The scheduler of the kernel.
pub const Scheduler = struct {
    /// The storage of the tasks. The address of a task has to be stable,
    /// because the context of a task is referred to by pointer.
    storage: [max_tasks]Task = @splat(.{}),
    /// The tasks of the kernel, in the order of their creation.
    tasks: [max_tasks]?*Task = @splat(null),
    /// The number of tasks that exist.
    count: u32 = 0,
    /// The task that is running on each CPU.
    ///
    /// O indice e o numero logico da CPU. Apenas o BSP executa tarefas
    /// hoje; os APs entram no laco de espera e nao tocam nesta tabela.
    current: [smp.max_cpus]?*Task = @splat(null),

    /// Fila de tarefas prontas de cada CPU.
    ///
    /// O indice externo e o numero logico da CPU; o interno e a posicao
    /// na fila. A fila e um anel logico FIFO: a insercao acrescenta no
    /// fim e a remocao retira do inicio.
    ready_queue: [smp.max_cpus][max_tasks]?*Task = @splat(@splat(null)),

    /// Numero de tarefas prontas em cada fila.
    ready_count: [smp.max_cpus]u32 = @splat(0),
    /// The tasks that ended and whose slot is waiting for the reaper.
    ///
    /// A task marks itself terminated and asks a processor to collect it; the
    /// slot cannot be handed back by the task itself, because the slot holds
    /// the stacks that the task is running on. The link lives in the task
    /// (`reap_next`), so the list never allocates.
    reap_head: ?*Task = null,
    /// How many tasks are in the list of the reaper.
    reap_count: u32 = 0,
    /// The identifier of the next task that is created.
    next_id: u32 = 0,
    /// The state of the scheduler.
    statistics: Statistics = .{},

    /// The lock of everything above.
    ///
    /// Every entry point that reads or writes `tasks`, `current`, the ready
    /// queues or the statistics takes it, and every one releases it on the way
    /// out. The lock knows the CPU that holds it, so the nested calls that the
    /// scheduler makes in the course of one decision (`tick` → `prepareNext` →
    /// expiry → wake) are counted instead of deadlocking; see
    /// [`lock.zig`](lock.zig) for the contract, including the rule that the
    /// caller has to disable interrupts before it acquires: the timer already
    /// runs with them disabled, and the thread-side entry points take the lock
    /// on a path where the kernel has disabled them as well.
    state_lock: lock.StateLock = .{},

    /// The CPU that is running this code.
    fn cpu(self: *const Scheduler) u8 {
        _ = self;
        return smp.cpuId();
    }

    /// Takes the state lock for the current CPU.
    fn lockState(self: *Scheduler) void {
        _ = self.state_lock.acquire(self.cpu());
    }

    /// Releases the state lock for the current CPU.
    fn unlockState(self: *Scheduler) void {
        _ = self.state_lock.release(self.cpu());
    }

    /// Returns the task that is running on the current CPU.
    pub fn currentTask(self: *Scheduler) ?*Task {
        return self.current[smp.cpuId()];
    }

    /// Enfileira uma tarefa na fila de prontos de uma CPU.
    ///
    /// A tarefa passa a ser considerada pronta para ser escolhida quando a
    /// CPU esvaziar a fila. A funcao ignora silenciosamente filas cheias:
    /// o limite de `max_tasks` ja protege o armazenamento.
    pub fn enqueueReady(self: *Scheduler, task: *Task, cpu_id: u8) void {
        self.lockState();
        defer self.unlockState();
        if (cpu_id >= smp.max_cpus) return;
        if (self.ready_count[cpu_id] >= max_tasks) return;
        // A task belongs to the CPU whose queue holds it: the choice of another
        // CPU never sees it, and the ownership travels with the queueing
        // (a task woken by an interrupt of CPU 1 is chosen by CPU 1).
        task.cpu = cpu_id;
        self.ready_queue[cpu_id][self.ready_count[cpu_id]] = task;
        self.ready_count[cpu_id] += 1;
    }

    /// Retira a proxima tarefa da fila de prontos de uma CPU.
    ///
    /// Retorna null quando a fila esta vazia.
    pub fn dequeueReady(self: *Scheduler, cpu_id: u8) ?*Task {
        self.lockState();
        defer self.unlockState();
        if (cpu_id >= smp.max_cpus) return null;

        // A task that ended is taken out of the queue on the way, and the walk
        // goes on: a terminated task that a wake enqueued before it ended is
        // not a task anybody may choose, and it must not hide the ready ones
        // behind it either.
        while (self.ready_count[cpu_id] > 0) {
            const task = self.ready_queue[cpu_id][0];
            self.shiftQueue(cpu_id);
            if (task) |value| {
                if (value.state == .terminated) continue;
            }
            return task;
        }
        return null;
    }

    /// Removes the first entry of the queue of a CPU.
    fn shiftQueue(self: *Scheduler, cpu_id: u8) void {
        var index: u32 = 0;
        while (index + 1 < self.ready_count[cpu_id]) : (index += 1) {
            self.ready_queue[cpu_id][index] = self.ready_queue[cpu_id][index + 1];
        }
        self.ready_count[cpu_id] -= 1;
        self.ready_queue[cpu_id][self.ready_count[cpu_id]] = null;
    }

    /// Numero de tarefas prontas na fila de uma CPU.
    pub fn readyCount(self: *Scheduler, cpu_id: u8) u32 {
        if (cpu_id >= smp.max_cpus) return 0;
        return self.ready_count[cpu_id];
    }

    /// Prepares the scheduler and captures the context of the task that is
    /// running, which becomes the first task.
    ///
    /// `kernel_stack_top` is the top of the stack that the boot left, and it
    /// is the stack where the code of the first task runs. `kernel_stack` is
    /// the stack of the kernel of the first task, and it is a different
    /// memory: the frame of an interrupt is built on it, and the frame
    /// cannot live in the stack that the code of the task uses.
    pub fn init(self: *Scheduler, kernel_stack_top: u64, kernel_stack: []u8) void {
        self.lockState();
        defer self.unlockState();
        self.tasks = @splat(null);
        self.count = 0;
        self.current = @splat(null);
        self.next_id = 0;
        self.statistics = .{};

        // The smallest switch is measured, the first one is the reference.
        kynox_switch_minimum = std.math.maxInt(u64);

        const task = self.allocate() orelse return;
        kynox_capture_context(&task.context);
        // The first task runs on the stack of the kernel that the boot left,
        // and the handlers of the calls and of the interrupts run on the
        // stack of the kernel of the task.
        task.stack = @as([*]u8, @ptrFromInt(kernel_stack_top))[0..0];
        task.kernel_rsp = stackTop(kernel_stack);
        initializeStackCanary(task, kernel_stack);
        task.state = .running;
        task.priority = 0;
        self.current[0] = task;
        segment.tssFor(smp.cpuId()).rsp0 = task.kernel_rsp;
        kynox_kernel_stack_pointer = task.kernel_rsp;
    }

    /// The stack where the idle task runs, and the kernel stack that the
    /// handlers of the idle task use.
    ///
    /// They live in the scheduler because the idle task is the one task that
    /// nobody else can create: it has no owner, no process and no address
    /// space, and it exists for as long as the CPU does.
    var idle_user_stacks: [smp.max_cpus][8 * 1024]u8 align(16) = @splat(@splat(0));
    var idle_kernel_stacks: [smp.max_cpus][8 * 1024]u8 align(16) = @splat(@splat(0));

    /// Halts the processor until the next interrupt.
    ///
    /// This is the body of the idle task. `sti; hlt` is the pair that matters:
    /// without the `sti` the halt would never return on a processor that
    /// arrived here with interrupts disabled, and the machine would stop for
    /// ever instead of idling.
    fn idleEntry() void {
        while (true) {
            x86_cpu.waitForInterrupt();
        }
    }

    /// Creates the idle task, if it does not exist yet.
    ///
    /// The task is marked `is_idle`, so the policy only chooses it when nothing
    /// else can run, and it is given the largest virtual runtime that the queue
    /// allows, so that it is the last candidate even among idle tasks. The
    /// function is idempotent and returns the existing task on the second call.
    ///
    /// The idle task is created in **ring 3** (`spawnUser`), which is not the
    /// same thing as "every task is ring 3": `spawn` creates a task of the
    /// kernel, in ring 0, and the workers of the boot are those. The idle task
    /// is ring 3 because its body is user code and the halt happens in the
    /// kernel on the way back from the interrupt — the task itself owns
    /// nothing, so it is given the weakest privilege the switch knows how to
    /// return to.
    ///
    /// Each CPU has one: the last resort of a processor has to belong to that
    /// processor, or the other CPU would take it and this one would have an
    /// empty queue at the moment it has nothing to run.
    pub fn ensureIdle(self: *Scheduler, cpu_id: u8) ?*Task {
        self.lockState();
        defer self.unlockState();

        // A number that the table of CPUs does not have is clamped instead of
        // indexing outside it: the processor is the last one, which is better
        // than a task of no CPU at all.
        const slot = @min(cpu_id, smp.max_cpus - 1);

        // One idle task per CPU: the last resort of a processor has to be a
        // task of that processor, or the other CPU would take it and the queue
        // of this one would be empty at the moment it has nothing to run.
        for (self.tasks[0..self.count]) |entry| {
            const task = entry orelse continue;
            if (task.is_idle and task.cpu == slot) return task;
        }

        const idle = self.spawnUser(
            @intFromPtr(&idleEntry),
            @intFromPtr(&idle_user_stacks[slot]),
            idle_user_stacks[slot].len,
            &idle_kernel_stacks[slot],
            0,
            null,
            0,
        ) orelse return null;
        idle.is_idle = true;
        idle.cpu = slot;
        idle.vruntime = policy.idleVruntime;

        return idle;
    }

    /// Moves a task to the queue of another CPU.
    ///
    /// This is the only way a task reaches a processor other than the one that
    /// created it, and it is what makes an application processor useful: the
    /// tasks of the boot are created by the BSP, so without a migration an AP
    /// would have an idle task and nothing else.
    ///
    /// The task has to be **ready** or **blocked**: a running task is on a
    /// processor and would keep running there while its owner changed, and a
    /// terminated one is not scheduled again. The queueing goes through
    /// `enqueueReady`, which records the new owner, and the destination CPU is
    /// kicked when it is not this one — its queue just stopped being empty.
    pub fn migrateTo(self: *Scheduler, task: *Task, cpu_id: u8) bool {
        self.lockState();
        defer self.unlockState();

        if (cpu_id >= smp.max_cpus) return false;
        if (task.cpu == cpu_id) return false;
        if (task.state == .running or task.state == .terminated) return false;

        const was_ready = task.state == .ready;
        task.cpu = cpu_id;

        if (was_ready) {
            self.enqueueReady(task, cpu_id);
            if (cpu_id != smp.cpuId()) {
                _ = smp.reschedule(cpu_id);
            }
        }

        return true;
    }

    /// Gives the calling CPU a task of its own.
    ///
    /// An application processor arrives from the trampoline in ring 0, on a
    /// stack that the BSP filled in, and with no task at all. A context switch
    /// saves the outgoing context, and the only thing the AP has to save is
    /// itself: without this task, `current[cpu]` is null, `prepareNext` returns
    /// false before it looks at the queue, and the queue of the CPU is never
    /// consulted — the AP would halt for ever with work waiting for it.
    ///
    /// The task is the kernel thread of the CPU: ring 0, the stack the
    /// trampoline gave it, and the state `running`. It is **not** put in the
    /// ready queue, because it is already running; it becomes ready only when a
    /// switch takes the processor from it, which is what `prepareNext` does when
    /// it finds a task of this CPU.
    ///
    /// The function is a no-op that returns the existing task when the CPU
    /// already has one, and returns null when the pool is full.
    pub fn adoptKernelTask(self: *Scheduler, cpu_id: u8, kernel_stack_top: u64, stack: []u8) ?*Task {
        self.lockState();
        defer self.unlockState();

        if (cpu_id >= smp.max_cpus) return null;
        if (self.current[cpu_id]) |existing| return existing;

        const task = self.allocate() orelse return null;
        task.cpu = cpu_id;
        task.state = .running;
        task.stack = stack;
        task.kernel_rsp = kernel_stack_top;
        task.quantum = 0;
        task.context = .{
            .rsp = kernel_stack_top,
            .rflags = 0x202,
            .rip = 0,
            .cs = kernel_code_selector,
            .ss = kernel_data_selector,
        };

        self.current[cpu_id] = task;
        self.statistics.entered_cpus = self.statistics.entered_cpus +| 1;

        return task;
    }

    /// Spawns a new task that starts at `entry` with the given stack.
    ///
    /// The stack of the task has to be aligned to sixteen bytes and to be
    /// large enough for the frame of the entry function. The stack of the
    /// kernel of the task is a different memory, and it receives the frames
    /// of the interrupts and of the calls.
    ///
    /// The priority of the new task is set to `priority` (0-255), with 0 being
    /// the default and higher values meaning higher priority. If `priority` is
    /// not specified, it defaults to 0.
    pub fn spawn(self: *Scheduler, entry: *const fn () void, stack: []u8, kernel_stack: []u8, priority: u8) ?*Task {
        self.lockState();
        defer self.unlockState();

        if (stack.len < 256) return null;
        if (kernel_stack.len < 256) return null;

        const task = self.allocate() orelse return null;

        // The task starts with the stack that the kernel gave it, and it
        // continues at the function that was chosen for it.
        const top = @intFromPtr(stack.ptr) + stack.len;
        const aligned = top & ~@as(usize, 0xF);
        // The function entry expects `RSP + 8` to be aligned to 16 bytes,
        // because a call would have pushed the return address. The task is
        // not called, so the initial stack emulates that call frame.
        const entry_stack = aligned - 8;

        task.context = .{
            .rsp = entry_stack,
            // The interrupt flag and the reserved bit of the flags.
            .rflags = 0x202,
            .rip = @intFromPtr(entry),
            .cs = kernel_code_selector,
            .ss = kernel_data_selector,
        };
        task.stack = stack;
        task.kernel_rsp = stackTop(kernel_stack);
        task.state = .ready;
        task.priority = priority;
        initializeStackCanary(task, kernel_stack);

        // O EEVDF herda o menor vruntime das tarefas prontas, para que a
        // tarefa nova nao seja adiada indefinidamente.
        // A new task starts at the smallest virtual runtime of the tasks that
        // can run, so that it is not given the processor for an unbounded
        // stretch; the deadline is one slice of its weight above that, which
        // is the same number the accounting charges when it runs.
        const entries = self.describeQueue(task);
        task.vruntime = policy.minVruntime(&entries) orelse 0;
        task.deadline = policy.deadlineFor(task.vruntime, task.slice, task.weight);

        return task;
    }

    /// Creates a task that runs in the third level of privilege.
    ///
    /// The task starts at `entry` with the stack of the user mode. The stack
    /// is described by its virtual address, because the task only knows the
    /// virtual address space.
    ///
    /// The task receives the address of its own window in the first
    /// register, which is the way a process learns where its memory is when
    /// it starts.
    pub fn spawnUser(
        self: *Scheduler,
        entry: u64,
        user_stack_address: u64,
        user_stack_length: u64,
        kernel_stack: []u8,
        window_base: u64,
        space: ?*paging.AddressSpace,
        role: u64,
    ) ?*Task {
        if (user_stack_length < 1024 or kernel_stack.len < 256) return null;

        const task = self.allocate() orelse return null;

        const user_top = (user_stack_address + user_stack_length) & ~@as(u64, 0xF);
        // The entry of a function expects `RSP + 8` to be aligned to 16
        // bytes, because a call would have pushed the return address. The
        // task is not called, but a freestanding compiler may still use
        // aligned SSE spills in the prologue: the initial stack emulates
        // the frame of a call so that those spills are valid.
        const user_entry = user_top - 8;

        task.context = .{
            .rbx = window_base,
            .rcx = role,
            .rsp = user_entry,
            .rflags = 0x202,
            .rip = entry,
            .cs = user_code_selector,
            .ss = user_data_selector,
        };
        task.stack = @as([*]u8, @ptrFromInt(user_stack_address))[0..@intCast(user_stack_length)];
        // The handlers of the task run on the stack of the kernel that the
        // kernel gave it, and not on the stack of the user.
        task.kernel_rsp = stackTop(kernel_stack);
        initializeStackCanary(task, kernel_stack);
        task.space = space;
        task.state = .ready;

        return task;
    }

    /// Counts a tick of the timer and decides whether the processor has to
    /// run another task.
    ///
    /// The waits whose deadline has passed expire **before** the next task
    /// is chosen, so that a task that timed out is ready in the same tick.
    /// `timeout_result` is the result of the call that timed out: the
    /// scheduler does not know the code of the error, because the contract
    /// of the calls is what owns it.
    ///
    /// The function is called by the handler of the timer. When it returns
    /// true, the entry point of the interrupt switches to the next task.
    pub fn tick(self: *Scheduler, timeout_result: u64) bool {
        self.lockState();
        defer self.unlockState();
        self.statistics.ticks += 1;
        _ = channel.expireAll(self.statistics.ticks, timeout_result);

        // The slots of the tasks that ended go back to the pool here, and not
        // when they end: the code of a task runs on the slot that would be
        // released. This is the only context that collects them, and it is the
        // path of the clock, which runs on every processor.
        _ = self.reap();

        return self.prepareNext();
    }

    /// Prepares the switch to the next task that can be chosen.
    ///
    /// The function is used by the timer and by the blocking of a task: in
    /// both cases the task that leaves is saved, and the next task is
    /// chosen and prepared. The difference is that the blocking is not a
    /// tick of the timer, and therefore the tick counter does not move.
    fn prepareNext(self: *Scheduler) bool {
        return self.decideNext(false);
    }

    /// Re-evaluates the queue of this CPU because another CPU asked for it.
    ///
    /// This is the handler of the reschedule IPI, and it is **not** a tick: the
    /// tick of the system belongs to one clock (`timer.TickSource`), so counting
    /// this as one would make the timeouts of the waiting tasks depend on how
    /// often another processor happened to wake somebody. The quantum does not
    /// move either: the task keeps the slice it has and leaves only if another
    /// task of this CPU can run now.
    pub fn rescheduleCurrent(self: *Scheduler) bool {
        self.lockState();
        defer self.unlockState();
        self.statistics.reschedules += 1;
        return self.decideNext(true);
    }

    /// Chooses the next task, and prepares the switch when there is one.
    ///
    /// `forced` is the difference between a tick and a reschedule: a tick only
    /// takes the processor from the task when its quantum ended, a reschedule
    /// takes it as soon as another task of this CPU is ready.
    fn decideNext(self: *Scheduler, forced: bool) bool {
        const current = self.current[smp.cpuId()] orelse return false;

        // Decrement the quantum of the current task, and preempt it if it
        // has expired. A quantum of zero means the task is not subject to
        // time-slicing.
        //
        // Only a task that is still running may be returned to the ready
        // queue here. The blocking paths mark the task as blocked **before**
        // they call this function; without the guard, a quantum that expired
        // in the same tick would turn the blocked task ready again and it
        // would resume with the neutral result of the call before the event
        // or the message arrives.
        //
        // A task that is still running and has a quantum left keeps the
        // processor: the tick only moves the clock. Switching on every tick
        // would turn the quantum into a decoration and would give the
        // processor to the task with the smallest virtual runtime on every
        // interruption, whatever the slice of the task that was running.
        var must_switch = current.state != .running;
        var preempted = false;

        // A reschedule does not consume the slice: the quantum is the exchange
        // rate between processor time and the policy, and only a tick may move
        // it. A decision taken because another CPU asked for it leaves the
        // quantum exactly where the last tick left it.
        if (!forced and policy.shouldPreempt(current.state == .running, current.quantum)) {
            current.quantum -= 1;
            if (current.quantum == 0) {
                // The current task has exhausted its quantum: return it to
                // the ready queue and choose the next task.
                current.state = .ready;
                // K3.12.2 fix: enqueue the ready task; previously missing.
                scheduler.enqueueReady(current, smp.cpuId());
                must_switch = true;
                preempted = true;
            }
        }

        // A reschedule does not touch the quantum: the task leaves because
        // somebody else can run, not because its slice ended.
        if (!must_switch and forced) {
            must_switch = self.findNextReady(current) != null;
        }

        if (!must_switch) return false;

        const next = self.findNextReady(current) orelse {
            // A task that exhausted its quantum and has nobody to hand the
            // processor to keeps it, with a new quantum: it is still the only
            // task that can run, and leaving it ready would be a task that no
            // tick ever chooses again.
            if (preempted) {
                current.state = .running;
                current.quantum = current.slice;
            }
            return false;
        };

        // The task that leaves becomes ready to be chosen again, and
        // **does not** become ready again when it is blocked: a task that
        // waits for a message is only chosen again when the message
        // arrives.
        if (current.state == .running) {
            current.state = .ready;
        }
        const leaving = current;
        const ptr_canary = @as(*const u64, @ptrFromInt(leaving.stack_canary_address));
        const stored_canary = @as(u64, ptr_canary.*);
        if (stored_canary != leaving.stack_canary) {
            var current_rsp: usize = undefined;
            asm volatile ("movq %%rsp, %[value]"
                : [value] "=r" (current_rsp),
            );
            kynox.serial.printLine("[KNK] PANIC: task {d} stack canary at 0x{x}: expected 0x{x}, got 0x{x}", .{
                leaving.id,
                leaving.stack_canary_address,
                leaving.stack_canary,
                stored_canary,
            });
            kynox.serial.printLine("[KNK] PANIC: current kernel RSP=0x{x}", .{current_rsp});
            @panic("stack corruption");
        }

        next.state = .running;
        self.current[smp.cpuId()] = next;
        next.schedules += 1;

        // The entering task gets the quantum of its slice. Without the
        // refill the task would keep the zero that the last slice left
        // behind, and the policy would stop preempting it for good: a task
        // would be time-sliced exactly once in its whole life.
        next.quantum = policy.quantumFor(next.slice);

        // EEVDF: the virtual runtime advances by the value of one slice of the
        // weight of the task (`policy.budgetFor`), which is the same number the
        // deadline of a new task uses. One function, one definition of the
        // exchange rate between processor time and virtual time.
        if (next.weight != 0) {
            next.vruntime += policy.budgetFor(next.slice, next.weight);
        }

        // The processor loads the stack pointer of the task state segment
        // whenever the privilege level changes, in both directions. The
        // stack of the task that is going to run is therefore the one that
        // the segment of task state points at, which is the stack of the
        // kernel of the task, and not the stack of the user.
        segment.tssFor(smp.cpuId()).rsp0 = next.kernel_rsp;
        kynox_kernel_stack_pointer = next.kernel_rsp;

        kynox_current_context = &current.context;
        kynox_next_context = &next.context;

        // The address space travels with the task: a process runs in the
        // space of its own, and the switch of the space happens together
        // with the switch of the context. The value is the root table of
        // the space that the entering task runs in, and zero means that the
        // space does not change.
        kynox_next_cr3 = 0;
        if (next.space != current.space) {
            if (next.space) |space| {
                kynox_next_cr3 = paging.spaceRoot(space);
            } else {
                kynox_next_cr3 = paging.rootAddress();
            }
            // The module of the tables has to know which space is the
            // active one, because the checks of the ranges of the user mode
            // walk the tables of the active space.
            paging.setActiveSpace(next.space);
        }

        return true;
    }

    /// Blocks the current task waiting for a message.
    ///
    /// The function registers the wait in the queue of the channel, marks
    /// the task as blocked and prepares the switch to another task. The
    /// result of the call is written in the context saved of the task when
    /// the message arrives, and the task continues after the call, as if the
    /// call had answered at once.
    ///
    /// `timeout` is the number of ticks that the wait may last, counted
    /// from the current tick of the scheduler. Zero means that the wait
    /// does not expire. A timeout that would overflow the counter saturates,
    /// and the wait therefore expires at the end of the counter and not
    /// before.
    ///
    /// The function returns false when there is no other task to choose,
    /// and in that case the task is **not** blocked: the call returns the
    /// error of the wait that cannot happen, and the task continues.
    pub fn blockCurrent(self: *Scheduler, target: *channel.Channel, side: u64, timeout: u64) bool {
        self.lockState();
        defer self.unlockState();
        const task = self.current[smp.cpuId()] orelse return false;

        // The deadline is in the ticks of the scheduler, which is the
        // counter that the timer moves and the one that the expiry reads.
        const deadline = if (timeout == 0)
            0
        else
            self.statistics.ticks +| timeout;

        const waiter = channel.Waiter{
            .kind = &task.context.rax,
            .value = &task.context.rdx,
            .task = task,
            .wake = wakeTask,
            .deadline = deadline,
        };

        if (!target.wait(side, waiter)) return false;

        // The task stays blocked, and the scheduler does not choose it
        // until the message arrives.
        task.state = .blocked;
        self.statistics.blocks += 1;

        // With no other task to run, the blocking makes no sense: the task
        // would be the only one, and the wait would be a busy loop.
        if (!self.prepareNext()) {
            task.state = .running;
            _ = target.cancelWait(side, waiter);
            return false;
        }

        // The entry of the call knows that the task cannot go back to the
        // user mode, and hands the control to the scheduler.
        kynox_syscall_blocked = 1;

        return true;
    }

    /// Releases per-process file descriptors after the final live task
    /// of an address space terminates. Task IDs are not process IDs.
    fn releaseProcessFilesIfLast(self: *Scheduler, finished: *Task) void {
        const space = finished.space orelse return;
        for (self.tasks[0..self.count]) |candidate| {
            const other = candidate orelse continue;
            if (other == finished or other.state == .terminated) continue;
            if (other.space == space) return;
        }
        const fs = @import("../fs/fs.zig");
        fs.closeAll(space.id) catch {};
    }

    /// Kills the current task.
    ///
    /// The task is marked as terminated, and the scheduler does not choose
    /// it again. It is the fate of an exception that came from the user
    /// mode: the process has a defect, and the defect of a process does not
    /// bring the machine down.
    pub fn killCurrent(self: *Scheduler) void {
        self.lockState();
        defer self.unlockState();
        const task = self.current[smp.cpuId()] orelse return;
        if (task.state == .terminated) return;
        task.state = .terminated;
        task.exit_code = 1;
        self.releaseProcessFilesIfLast(task);
        self.statistics.killed += 1;
        self.requestReap(task);
    }

    /// Blocks the current task on a wait queue, with an optional deadline.
    ///
    /// This is the generic form of `blockCurrent`, and it is the one a mutex, a
    /// condition variable or a reader/writer lock uses: the caller owns the node
    /// (it lives in the task, or on the stack of the caller), the queue owns the
    /// order, and the scheduler owns the state of the task.
    ///
    /// The contract, in the order it happens:
    ///
    /// 1. the deadline is `timeout` ticks from now, or none when `timeout` is
    ///    zero, and it is written into the node **before** the node enters the
    ///    queue, so that the expiry can never see a node without one;
    /// 2. the node is queued, or it already is in this queue because the caller
    ///    registered the wait itself (the mutex does, since it hands the
    ///    ownership over at release time). A node that a wake already reached
    ///    (`already_woken`) or that is queued elsewhere is refused, and the
    ///    caller re-checks its predicate instead of sleeping;
    /// 3. the task is marked blocked and the switch is prepared;
    /// 4. when there is nobody to switch to, the task is marked running again,
    ///    the node leaves the queue and the call returns false: a wait that
    ///    cannot happen must not become a task that never wakes.
    pub fn blockCurrentOn(
        self: *Scheduler,
        queue: *wait_queue.WaitQueue,
        node: *wait_queue.Node,
        timeout: u64,
    ) bool {
        self.lockState();
        defer self.unlockState();

        const task = self.current[smp.cpuId()] orelse return false;

        node.deadline = if (timeout == 0) 0 else self.statistics.ticks +| timeout;

        switch (queue.add(node)) {
            .queued => {},
            // The caller registered the wait itself, which is what a mutex does:
            // the ownership is handed to the waiter at release time, so the
            // node is in the queue before the task goes to sleep. The node has
            // to be in **this** queue; one that is queued elsewhere is a defect
            // of the caller and is refused.
            .already_queued => if (!queue.contains(node)) return false,
            // A wake arrived before the waiter: there is nothing to sleep on,
            // and the caller re-checks its predicate.
            .already_woken => return false,
        }

        task.state = .blocked;
        self.statistics.blocks += 1;

        if (!self.prepareNext()) {
            task.state = .running;
            _ = queue.remove(node);
            return false;
        }

        // The entry of the call knows that the task cannot go back to the user
        // mode, and hands the control to the scheduler.
        kynox_syscall_blocked = 1;

        return true;
    }

    /// Wakes the task that waits for a message.
    ///
    /// The task becomes ready, and the scheduler chooses it on the next
    /// tick.
    pub fn wakeTask(task: *anyopaque) void {
        // The wake runs from the delivery of a message and from the expiry of
        // a wait, which are inside `tick` and inside the send: the state lock
        // is therefore taken through the same re-entrant path as every other
        // nested call, and this function is the one that proves the owner check
        // of the lock is worth having.
        scheduler.lockState();
        defer scheduler.unlockState();

        const value: *Task = @ptrCast(@alignCast(task));
        if (value.state == .terminated) return;
        value.state = .ready;

        // The task goes back to the queue of the CPU that owns it, which is not
        // necessarily the CPU that runs the waker. When it is not, that CPU has
        // to be told: it is asleep in `sti; hlt`, and no clock of this system
        // will wake it for this task.
        //
        // K3.12.2 fix: enqueue the ready task; previously missing.
        scheduler.enqueueReady(value, value.cpu);
        if (value.cpu != smp.cpuId()) {
            if (smp.reschedule(value.cpu) == .sent) {
                scheduler.statistics.wake_reschedules += 1;
            }
        }
    }

    /// Blocks the current task waiting for an input event.
    ///
    /// The wait is registered by the caller (the syscall of the input
    /// wait), not in a channel queue: the producer is the PS/2 interrupt
    /// filling the user queue, and the timer tick delivers the event or
    /// expires the wait. This function marks the task as blocked and
    /// prepares the switch, exactly like the channel wait.
    pub fn blockCurrentForInput(self: *Scheduler) bool {
        self.lockState();
        defer self.unlockState();
        const task = self.current[smp.cpuId()] orelse return false;
        task.state = .blocked;
        self.statistics.blocks += 1;

        if (!self.prepareNext()) {
            task.state = .running;
            return false;
        }

        // The entry of the call knows that the task cannot go back to the
        // user mode, and hands the control to the scheduler.
        kynox_syscall_blocked = 1;

        return true;
    }

    /// Ends the task that is running.
    ///
    /// The task is marked as terminated, and the scheduler does not choose
    /// it again. The processor keeps running the task until the next
    /// interruption, and the task does not have to know that it ended.
    pub fn terminateCurrent(self: *Scheduler, code: u64) void {
        self.lockState();
        defer self.unlockState();
        const current = self.current[smp.cpuId()] orelse return;
        if (current.state == .terminated) return;
        current.state = .terminated;
        current.exit_code = code;
        self.releaseProcessFilesIfLast(current);
        self.requestReap(current);
    }

    /// The state of the scheduler, with the measurements of the switches.
    ///
    /// The function does **not** take the state lock, and it does not pretend
    /// to be consistent: it runs from the diagnostics of the serial console,
    /// where a reading that a tick changed in the middle is worth more than a
    /// deadlock. `lock_contentions`, `lock_reentries` and `lock_max_depth` come
    /// from the lock itself, and the first two are the measurement of how often
    /// the lock was actually needed.
    pub fn statisticsOf(self: *const Scheduler) Statistics {
        var statistics = self.statistics;
        statistics.switches = kynox_switch_count;
        statistics.switch_cycles = kynox_switch_total;
        statistics.last_switch_cycles = kynox_switch_cycles;
        statistics.minimum_switch_cycles = kynox_switch_minimum;
        statistics.lock_contentions = self.state_lock.contentions;
        statistics.lock_reentries = self.state_lock.reentries;
        statistics.lock_max_depth = self.state_lock.max_depth;
        statistics.lock_refused_releases = self.state_lock.refused_releases;
        // The tasks that exist, not the tasks that ever existed: a slot that
        // the reaper handed back is not a task, and `count` is the high-water
        // mark of the list, which a reaped slot may sit below.
        var existing: u32 = 0;
        var ready: u32 = 0;
        var blocked: u32 = 0;
        statistics.idle = -1;
        for (self.tasks) |task| {
            const value = task orelse continue;
            existing += 1;
            if (value.state == .ready) ready += 1;
            if (value.state == .blocked) blocked += 1;
            if (value.is_idle and value.cpu == smp.cpuId()) statistics.idle = @intCast(value.id);
        }
        statistics.tasks = existing;
        statistics.ready = ready;
        statistics.blocked = blocked;

        return statistics;
    }

    /// Finds the next task that is ready.
    ///
    /// The choice itself is not here: it is `policy.pickNext`, a pure function
    /// over a flat description of the queue, tested on its own. This function
    /// is the adapter — it builds that description from the task objects
    /// (which requires knowing what a process is, and that is state, not
    /// policy) and maps the answer back to a task.
    ///
    /// The description keeps one entry per slot, including the slots that
    /// cannot run, so that the ring of the policy walks the same order as the
    /// list of the scheduler and the answer is the slot itself.
    fn findNextReady(self: *const Scheduler, current: *Task) ?*Task {
        const entries = self.describeQueue(current);
        const chosen = policy.pickNext(&entries, self.indexOf(current)) orelse return null;
        return self.tasks[chosen];
    }

    /// The task that the policy would choose after `current`.
    ///
    /// The production path is `findNextReady`, which is private; this accessor
    /// exists so that a test can ask the same question without switching.
    fn findNextReadyForTest(self: *const Scheduler, current: *Task) ?*Task {
        return self.findNextReady(current);
    }

    /// Describes the queue as the policy sees it.
    ///
    /// A slot is eligible when it holds a task, the task is ready, it is not
    /// the task that is leaving, and the process of the task is not leaving:
    /// the threads of a process that is `exiting` or `reaped` are not
    /// scheduled, because their address space is on its way out.
    fn describeQueue(self: *const Scheduler, current: *Task) [max_tasks]policy.Entry {
        var entries: [max_tasks]policy.Entry = undefined;
        const this_cpu = current.cpu;

        for (self.tasks, 0..) |slot, index| {
            entries[index] = .{ .index = index, .vruntime = 0, .eligible = false };

            const task = slot orelse continue;
            if (task == current) continue;
            if (task.state != .ready) continue;
            // The queue of a CPU holds the tasks of that CPU. A task of
            // another processor is not a candidate here: choosing it would
            // give one stack and one saved context to two processors.
            if (task.cpu != this_cpu) continue;
            if (task.process_ref) |process_ref| {
                const state = process_ref.state;
                if (state == .exiting or state == .reaped) continue;
            }

            entries[index] = .{
                .index = index,
                .vruntime = task.vruntime,
                .eligible = true,
                .idle = task.is_idle,
            };
        }

        return entries;
    }

    /// The position of a task in the list of the scheduler.
    fn indexOf(self: *const Scheduler, task: *Task) usize {
        for (self.tasks, 0..) |entry, index| {
            const value = entry orelse continue;
            if (value == task) return index;
        }
        return 0;
    }

    /// Reserves a slot of the storage of the scheduler.
    ///
    /// The first free slot is used, and not the one after the last task that
    /// was created: a task that ended hands its slot back (`reap`), and a
    /// counter that only grew would turn the 33rd task of the life of the
    /// machine into a creation that fails, however few tasks exist at that
    /// moment. `max_tasks` bounds the tasks that exist **at the same time**,
    /// which is what the storage holds, and not the tasks that ever existed.
    ///
    /// The walk covers `0..count`, which is the prefix of the list that was
    /// ever handed out: a slot above it has never been used, and the first of
    /// them is the answer when no hole exists below.
    fn allocate(self: *Scheduler) ?*Task {
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            if (self.tasks[index] == null) break;
        }
        if (index >= max_tasks) return null;

        const task = &self.storage[index];
        task.* = .{
            .id = self.next_id,
            .state = .ready,
            .quantum = 16,
            .cpu = smp.cpuId(),
            // A fresh slot is not in the list of the reaper: the task that
            // used it before it was handed back left it.
            .reap_next = null,
            .reap_queued = false,
        };
        self.next_id += 1;
        self.tasks[index] = task;
        if (index >= self.count) self.count = index + 1;

        return task;
    }

    /// Asks for the slot of a task that ended to be handed back.
    ///
    /// The task that calls this is still running on the slot, so nothing is
    /// freed here: the task enters the list of the reaper and the next `reap`
    /// — run by whoever holds the processor afterwards — releases the slot. A
    /// task that is already in the list does not enter twice.
    ///
    /// The idle task is never collected: the last resort of a processor has to
    /// exist for as long as the processor does, and `ensureIdle` would only
    /// create another one on the same slot the moment it was asked again.
    pub fn requestReap(self: *Scheduler, task: *Task) void {
        self.lockState();
        defer self.unlockState();
        self.enqueueReap(task);
    }

    /// Puts a terminated task in the list of the reaper.
    ///
    /// The caller already holds the state lock.
    fn enqueueReap(self: *Scheduler, task: *Task) void {
        if (task.state != .terminated) return;
        if (task.is_idle) return;
        if (task.reap_queued) return;

        task.reap_next = self.reap_head;
        task.reap_queued = true;
        self.reap_head = task;
        self.reap_count += 1;
        self.statistics.pending_reap = self.reap_count;
    }

    /// Hands back the slots of the tasks that ended.
    ///
    /// The function runs from the tick, which is the only context that is
    /// neither the task being collected nor a caller that may already be inside
    /// the scheduler for another reason. The slot of a task that a processor is
    /// still running is left alone — it has not switched away from it yet — and
    /// so is a slot that cannot be collected (`mayCollect`): the task stays in
    /// the list, and the count of the tasks that are pending is what makes that
    /// visible in the report of the boot.
    ///
    /// Returns how many slots went back to the pool.
    pub fn reap(self: *Scheduler) u32 {
        self.lockState();
        defer self.unlockState();

        var released: u32 = 0;
        var link = &self.reap_head;
        while (link.*) |task| {
            if (task.state != .terminated or self.isRunning(task) or !self.mayCollect(task)) {
                link = &task.reap_next;
                continue;
            }

            // The task leaves the list before its slot is cleared, because the
            // link itself lives in the slot that is about to become empty.
            link.* = task.reap_next;
            task.reap_queued = false;
            self.reap_count -= 1;
            self.releaseSlot(task);
            released += 1;
        }

        self.statistics.reaped += released;
        self.statistics.pending_reap = self.reap_count;
        return released;
    }

    /// Whether a CPU is running the task right now.
    fn isRunning(self: *const Scheduler, task: *Task) bool {
        for (self.current) |entry| {
            if (entry == task) return true;
        }
        return false;
    }

    /// Whether a task may be collected now.
    ///
    /// Two conditions come from the machine, and the reason they exist is that
    /// the slot of a task holds more than a number:
    ///
    ///   - the kernel stack of the task still has the canary the task was
    ///     given. A stack that was overwritten is evidence of a defect, and a
    ///     slot that receives another task would overwrite the evidence;
    ///   - a task that ended while it was blocked stays in the list. The slot
    ///     holds the node that the wait queue points at, and a slot that
    ///     becomes another task while a queue still names it is corruption.
    ///
    /// The canary is not checked for a task that never received a kernel stack
    /// (the host tests create tasks without one), and it is not checked on the
    /// host at all, where the address of a stack is an address of the test
    /// process and not of a kernel image.
    fn mayCollect(self: *const Scheduler, task: *Task) bool {
        _ = self;
        if (builtin.target.os.tag != .freestanding) return true;
        if (task.stack_canary == 0 or task.stack_canary_address == 0) return true;
        const stored = @as(*const u64, @ptrFromInt(task.stack_canary_address)).*;
        return stored == task.stack_canary;
    }

    /// Returns the slot of a task to the pool.
    ///
    /// The slot goes back to the storage and the entry of the list becomes
    /// null, which is what lets `allocate` hand the same index out again. The
    /// identifier of the task is **not** reused: `next_id` only grows, so an
    /// identifier that a caller kept from a task that ended names nothing
    /// afterwards, exactly like the generation of an address space makes the
    /// identity of a process the pair and not the slot.
    fn releaseSlot(self: *Scheduler, task: *Task) void {
        const index = self.indexOf(task);
        if (index >= self.count) return;
        if (self.tasks[index] != task) return;

        // Every queue that still names the task is purged first. The slot is
        // about to become a task of its own, and a queue that kept the address
        // would hand the new task out twice — the reference is the pointer, not
        // the identifier, so an entry of a terminated task is a reference to
        // whatever receives the slot next.
        self.purgeReady(task);

        self.tasks[index] = null;
        task.* = .{};
    }

    /// Removes every entry of a task from the ready queues of every CPU.
    fn purgeReady(self: *Scheduler, task: *Task) void {
        for (0..smp.max_cpus) |cpu_id| {
            var write: u32 = 0;
            var read: u32 = 0;
            while (read < self.ready_count[cpu_id]) : (read += 1) {
                const entry = self.ready_queue[cpu_id][read];
                if (entry == task) continue;
                self.ready_queue[cpu_id][write] = entry;
                write += 1;
            }
            // The entries above the new tail are cleared, and the count is the
            // number that survived: the clearing must not move the counter that
            // the queue is measured by.
            const survivors = write;
            while (write < self.ready_count[cpu_id]) : (write += 1) {
                self.ready_queue[cpu_id][write] = null;
            }
            self.ready_count[cpu_id] = @intCast(survivors);
        }
    }
};

/// The scheduler of the kernel.
pub var scheduler: Scheduler = .{};

/// The top of a stack, aligned to sixteen bytes.
///
/// The stack of a task grows towards the low addresses, therefore the top is
/// the end of the region, and the first frame of the kernel is built below
/// it.
fn stackTop(stack: []u8) u64 {
    const top = @intFromPtr(stack.ptr) + stack.len;
    return top & ~@as(u64, 0xF);
}

fn initializeStackCanary(task: *Task, kernel_stack: []u8) void {
    task.stack_canary = cpu.readTimestamp() ^ @as(u64, task.id);
    const stack_base = @intFromPtr(kernel_stack.ptr);
    const canary_address = std.mem.alignForward(usize, stack_base, @alignOf(u64));
    task.stack_canary_address = canary_address;
    const canary_ptr: *u64 = @ptrFromInt(canary_address);
    canary_ptr.* = task.stack_canary;
}

/// The context of the task that is leaving, used by the switch.
pub extern var kynox_current_context: *Context;

/// The context of the task that is entering, used by the switch.
pub extern var kynox_next_context: *Context;

/// The number of switches between tasks.
pub extern var kynox_switch_count: u64;

/// The total cost of the switches, in cycles.
pub extern var kynox_switch_total: u64;

/// The cost of the last switch, in cycles.
pub extern var kynox_switch_cycles: u64;

/// The smallest cost of a switch, in cycles.
pub extern var kynox_switch_minimum: u64;

/// The stack of the kernel of the task that is running.
pub extern var kynox_kernel_stack_pointer: u64;

/// The root table of the address space of the task that is entering.
///
/// The value is zero when the address space does not change, and the switch
/// reads it to know whether it has to write the register of the tables.
pub extern var kynox_next_cr3: u64;

/// The flag that tells the entry of the system call that the task blocked.
///
/// The value is one when the current task was left waiting for a
/// message, and the entry of the call hands the control to the scheduler
/// instead of going back to the user mode.
pub extern var kynox_syscall_blocked: u64;

/// Captures the context of the task that is running.
extern fn kynox_capture_context(task_context: *Context) callconv(.c) void;


/// K4.9 / K3.12.2: preempt_disable real — desabilita interrupções (CLI) com contador por CPU.
pub fn preempt_disable() void {
    // CLI: disable maskable interrupts.
    asm volatile ("cli");
    // Increment per-CPU preemption counter (nesting safe).
    const id = @import("../arch/x86_64/smp.zig").cpuId();
    preempt_counter[id] += 1;
}

/// K4.9 / K3.12.2: preempt_enable real — restaura interrupções (STI) com nesting.
pub fn preempt_enable() void {
    const id = @import("../arch/x86_64/smp.zig").cpuId();
    // Underflow protection.
    if (preempt_counter[id] > 0) {
        preempt_counter[id] -= 1;
    }
    // Only re-enable interrupts if counter reaches zero.
    if (preempt_counter[id] == 0) {
        asm volatile ("sti");
    }
}

/// Per-CPU preemption counter (max 255 nesting depth).
var preempt_counter: [256]u8 = @splat(0);

// ---------------------------------------------------------------------------
// The tests of the policy
// ---------------------------------------------------------------------------
//
// The mechanism (the switch, the TSS, the CR3 load) is assembly and cannot run
// on the host. The policy can: the ready queue, the choice of the next task, the
// admission of a new task and the accounting. Those are the parts that were
// written without a single test until 2026-11-01, which is defect 1 of the
// audit: "the scheduler has no synchronisation and no tests".
//
// What these tests do not prove: that a switch works, that the scheduler is safe
// under SMP, or that the canary check runs. They prove the decisions.

const testing = std.testing;

/// Clears the scheduler state so that each test starts from zero.
fn resetSchedulerForTest() void {
    scheduler.storage = @splat(.{});
    scheduler.tasks = @splat(null);
    scheduler.count = 0;
    scheduler.current = @splat(null);
    scheduler.ready_queue = @splat(@splat(null));
    scheduler.ready_count = @splat(0);
    scheduler.next_id = 0;
    scheduler.reap_head = null;
    scheduler.reap_count = 0;
    scheduler.statistics = .{};
    scheduler.state_lock = .{};
}

/// A task that the tests put in the list of the scheduler.
fn taskForTest(vruntime: i64, state: State) *Task {
    const task = &scheduler.storage[scheduler.count];
    task.* = .{ .id = scheduler.next_id, .state = state, .quantum = 16, .vruntime = vruntime };
    scheduler.tasks[scheduler.count] = task;
    scheduler.count += 1;
    scheduler.next_id += 1;
    return task;
}

test "the ready queue is a fifo, and it accepts the whole pool" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var tasks: [3]*Task = undefined;
    for (&tasks, 0..) |*slot, index| {
        slot.* = taskForTest(@intCast(index), .ready);
        scheduler.enqueueReady(slot.*, 0);
    }

    try testing.expectEqual(@as(u32, 3), scheduler.readyCount(0));

    // The first task that entered leaves first.
    try testing.expectEqual(tasks[0], scheduler.dequeueReady(0).?);
    try testing.expectEqual(tasks[1], scheduler.dequeueReady(0).?);
    try testing.expectEqual(tasks[2], scheduler.dequeueReady(0).?);

    // An empty queue answers null instead of an old entry.
    try testing.expect(scheduler.dequeueReady(0) == null);
    try testing.expectEqual(@as(u32, 0), scheduler.readyCount(0));

    // A CPU that does not exist cannot be addressed.
    try testing.expect(scheduler.dequeueReady(smp.max_cpus) == null);
    scheduler.enqueueReady(tasks[0], smp.max_cpus);
    try testing.expectEqual(@as(u32, 0), scheduler.readyCount(0));
}

test "a full queue drops the newcomer and keeps the tasks it has" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var index: usize = 0;
    while (index < max_tasks) : (index += 1) {
        const task = taskForTest(@intCast(index), .ready);
        scheduler.enqueueReady(task, 0);
    }
    try testing.expectEqual(@as(u32, max_tasks), scheduler.readyCount(0));

    // The pool of the tasks is exhausted first, so the extra task is a task of
    // the storage that is not in the list; the queue is full and refuses it.
    const extra = &scheduler.storage[0];
    scheduler.enqueueReady(extra, 0);
    try testing.expectEqual(@as(u32, max_tasks), scheduler.readyCount(0));

    // Every queued task survives, in order: the refusal may not corrupt the
    // queue that is full.
    index = 0;
    while (index < max_tasks) : (index += 1) {
        const task = scheduler.dequeueReady(0).?;
        try testing.expectEqual(@as(u32, @intCast(index)), task.id);
    }
}

test "the next task is the ready one with the smallest virtual runtime" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    const current = taskForTest(10, .running);
    scheduler.current[0] = current;

    const late = taskForTest(50, .ready);
    const early = taskForTest(5, .ready);
    const middle = taskForTest(20, .ready);

    // The choice is the minimum, not the creation order.
    try testing.expectEqual(early, scheduler.findNextReady(current).?);

    // A task that is running elsewhere, blocked or terminated is not a
    // candidate, even with the smallest runtime.
    early.state = .blocked;
    try testing.expectEqual(middle, scheduler.findNextReady(current).?);
    middle.state = .terminated;
    try testing.expectEqual(late, scheduler.findNextReady(current).?);

    // With no ready task the function answers null instead of the current task:
    // the caller decides what to do when nothing can run.
    late.state = .ready;
    late.state = .blocked;
    try testing.expect(scheduler.findNextReady(current) == null);
}

test "a thread of a process that is leaving is not scheduled" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    const current = taskForTest(0, .running);
    scheduler.current[0] = current;

    var leaving_process: process.Process = .{};
    leaving_process.state = .exiting;

    const orphan = taskForTest(1, .ready);
    orphan.process_ref = &leaving_process;
    const healthy = taskForTest(9, .ready);

    // The orphan has the smallest runtime and is still not chosen: scheduling
    // it would run code of a process that is being destroyed.
    try testing.expectEqual(healthy, scheduler.findNextReady(current).?);

    // Once the process is running again, the ordinary rule applies.
    leaving_process.state = .running;
    try testing.expectEqual(orphan, scheduler.findNextReady(current).?);
}

test "spawning refuses a stack that cannot hold a frame" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var small_stack: [128]u8 = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    // A stack below 256 bytes cannot hold the frame of the entry function.
    try testing.expect(scheduler.spawn(noopEntry, small_stack[0..], kernel_stack[0..], 0) == null);
    try testing.expectEqual(@as(u32, 0), scheduler.count);

    // The kernel stack has the same requirement.
    var task_stack: [1024]u8 align(16) = undefined;
    try testing.expect(scheduler.spawn(noopEntry, task_stack[0..], small_stack[0..], 0) == null);
    try testing.expectEqual(@as(u32, 0), scheduler.count);
}

test "a new task starts at the smallest runtime of the ready tasks" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    const slow = taskForTest(80, .ready);
    const fast = taskForTest(20, .ready);
    _ = slow;

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const task = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 7).?;

    // The newcomer inherits the minimum so that it is not postponed behind
    // tasks that accumulated runtime before it existed.
    try testing.expectEqual(fast.vruntime, task.vruntime);

    // The deadline is the slice scaled by the weight: 10 ticks at the unit
    // weight (1024) is ten ticks of virtual runtime.
    try testing.expectEqual(@as(i64, 10), task.deadline - task.vruntime);

    // The priority is the one the caller asked for, and the task starts ready
    // with the initial context of a kernel task.
    try testing.expectEqual(@as(u8, 7), task.priority);
    try testing.expectEqual(State.ready, task.state);
    try testing.expectEqual(kernel_code_selector, task.context.cs);
    try testing.expectEqual(kernel_data_selector, task.context.ss);
    try testing.expect(task.context.rsp % 16 == 8);
}

test "a heavier task earns virtual runtime more slowly when it runs" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    // Each task needs its own kernel stack: the canary of a task lives at the
    // base of that stack, and two tasks that shared one would overwrite each
    // other's canary and be killed on the next switch.
    var light_stack: [1024]u8 align(16) = undefined;
    var heavy_stack: [1024]u8 align(16) = undefined;
    var task_stack: [1024]u8 align(16) = undefined;

    const light = scheduler.spawn(noopEntry, task_stack[0..], light_stack[0..], 0).?;
    const heavy = scheduler.spawn(noopEntry, task_stack[0..], heavy_stack[0..], 0).?;
    heavy.weight = 2048;
    light.quantum = 1;
    light.state = .running;
    scheduler.current[0] = light;

    // The light task leaves when its quantum expires and the heavy one enters:
    // a slice of ten ticks at double weight is five ticks of virtual runtime.
    try testing.expect(scheduler.tick(0));
    try testing.expectEqual(heavy, scheduler.current[0].?);
    try testing.expectEqual(@as(i64, 5), heavy.vruntime);

    // The same slice at the unit weight is ten ticks.
    heavy.quantum = 1;
    try testing.expect(scheduler.tick(0));
    try testing.expectEqual(light, scheduler.current[0].?);
    try testing.expectEqual(@as(i64, 10), light.vruntime);
}

test "the task pool refuses the task after the last one" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stacks: [max_tasks][1024]u8 align(16) = undefined;

    var created: u32 = 0;
    while (created < max_tasks) : (created += 1) {
        const kernel_stack = kernel_stacks[created][0..];
        try testing.expect(scheduler.spawn(noopEntry, stack[0..], kernel_stack, 0) != null);
    }
    try testing.expectEqual(@as(u32, max_tasks), scheduler.count);

    // The pool is a hard limit and it is reported, not hidden behind a task
    // that never runs.
    try testing.expect(scheduler.spawn(noopEntry, stack[0..], kernel_stacks[0][0..], 0) == null);
    try testing.expectEqual(@as(u32, max_tasks), scheduler.count);
}

test "a tick moves the clock and lets a task with an expired quantum leave" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var first_kernel_stack: [1024]u8 align(16) = undefined;
    var second_kernel_stack: [1024]u8 align(16) = undefined;

    const first = scheduler.spawn(noopEntry, stack[0..], first_kernel_stack[0..], 0).?;
    const second = scheduler.spawn(noopEntry, stack[0..], second_kernel_stack[0..], 0).?;
    first.state = .running;
    second.state = .ready;
    scheduler.current[0] = first;
    first.quantum = 2;

    // The first tick spends one tick of the quantum: the task keeps running and
    // the scheduler does not switch.
    try testing.expect(scheduler.tick(0) == false);
    try testing.expectEqual(@as(u64, 1), scheduler.statistics.ticks);
    try testing.expectEqual(@as(u16, 1), first.quantum);
    try testing.expectEqual(first, scheduler.current[0].?);

    // The second tick exhausts it: the current task goes back to the queue and
    // the other one is chosen and charged with its slice.
    try testing.expect(scheduler.tick(0) == true);
    try testing.expectEqual(@as(u64, 2), scheduler.statistics.ticks);
    try testing.expectEqual(second, scheduler.current[0].?);
    try testing.expectEqual(State.ready, first.state);
    try testing.expectEqual(State.running, second.state);
    try testing.expectEqual(@as(u64, 1), second.schedules);
    try testing.expect(second.vruntime > 0);
}

test "a task that blocked does not come back because its quantum expired" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var waiter_kernel_stack: [1024]u8 align(16) = undefined;
    var other_kernel_stack: [1024]u8 align(16) = undefined;

    const waiter = scheduler.spawn(noopEntry, stack[0..], waiter_kernel_stack[0..], 0).?;
    const other = scheduler.spawn(noopEntry, stack[0..], other_kernel_stack[0..], 0).?;
    scheduler.current[0] = waiter;
    waiter.state = .blocked;
    waiter.quantum = 1;

    // The tick must not turn a blocked task ready: it would resume with a
    // result that never arrived. The switch happens; the state does not change.
    _ = scheduler.tick(0);
    try testing.expectEqual(State.blocked, waiter.state);
    try testing.expectEqual(other, scheduler.current[0].?);
}

/// The entry of a task that does nothing: the tests never run it.
fn noopEntry() void {}

test "the only task keeps the processor when its quantum expires" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const only = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    only.state = .running;
    only.quantum = 1;
    scheduler.current[0] = only;

    // The slice is spent and there is no other ready task: no switch happens,
    // and the task keeps running with the quantum of its slice. Without the
    // restoration the task would be left `ready` while it is the one on the
    // processor, and no tick would ever choose it again.
    try testing.expect(scheduler.tick(0) == false);
    try testing.expectEqual(only, scheduler.current[0].?);
    try testing.expectEqual(State.running, only.state);
    try testing.expectEqual(only.slice, only.quantum);

    // The tick still moves the clock.
    try testing.expectEqual(@as(u64, 1), scheduler.statistics.ticks);
}

test "every entry point of the scheduler leaves the state lock free" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const task = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    try testing.expect(!scheduler.state_lock.isHeld());

    task.state = .running;
    task.quantum = 4;
    scheduler.current[0] = task;

    _ = scheduler.tick(0);
    try testing.expect(!scheduler.state_lock.isHeld());
    try testing.expectEqual(@as(u32, 0), scheduler.state_lock.depth);

    Scheduler.wakeTask(task);
    try testing.expect(!scheduler.state_lock.isHeld());

    scheduler.terminateCurrent(0);
    try testing.expect(!scheduler.state_lock.isHeld());
    try testing.expectEqual(@as(u64, 0), scheduler.state_lock.refused_releases);
}

test "the nested calls of one decision are re-entries, not a deadlock" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const task = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    task.state = .ready;

    // The caller holds the lock, as the timer does, and then the scheduler is
    // called: the wake has to recognise the CPU instead of spinning on a lock
    // it holds itself.
    _ = scheduler.state_lock.acquire(0);
    Scheduler.wakeTask(task);
    try testing.expect(scheduler.state_lock.isHeldBy(0));
    try testing.expect(scheduler.state_lock.reentries >= 1);
    _ = scheduler.state_lock.release(0);

    try testing.expect(!scheduler.state_lock.isHeld());
    try testing.expect(State.ready == task.state);
}

test "a queue with a waiter outside the scheduler blocks the task and switches" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var first_kernel_stack: [1024]u8 align(16) = undefined;
    var second_kernel_stack: [1024]u8 align(16) = undefined;

    const first = scheduler.spawn(noopEntry, stack[0..], first_kernel_stack[0..], 0).?;
    const second = scheduler.spawn(noopEntry, stack[0..], second_kernel_stack[0..], 0).?;
    first.state = .running;
    second.state = .ready;
    scheduler.current[0] = first;
    first.quantum = 4;

    var queue: wait_queue.WaitQueue = .{};
    var node = wait_queue.Node.init(first, Scheduler.wakeTask);

    // One tick of the clock, so that the deadline of the wait is measurable.
    _ = scheduler.tick(0);

    try testing.expect(scheduler.blockCurrentOn(&queue, &node, 3));
    try testing.expectEqual(@as(u32, 1), queue.length());
    try testing.expectEqual(State.blocked, first.state);
    try testing.expectEqual(second, scheduler.current[0].?);
    // The clock is at one tick and the wait is three ticks long.
    try testing.expectEqual(@as(u64, 4), node.deadline);
    try testing.expect(!scheduler.state_lock.isHeld());

    // The event arrives: the wake takes the task out of the queue and makes it
    // ready, and the scheduler chooses it on the next opportunity.
    try testing.expectEqual(&node, queue.popAndWake().?);
    try testing.expectEqual(State.ready, first.state);
    try testing.expectEqual(@as(u32, 0), queue.length());
    try testing.expectEqual(@as(u32, 1), scheduler.readyCount(0));
}

test "a wait with nobody to switch to is undone" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const only = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    only.state = .running;
    only.quantum = 4;
    scheduler.current[0] = only;

    var queue: wait_queue.WaitQueue = .{};
    var node = wait_queue.Node.init(only, Scheduler.wakeTask);

    // There is no other task: the wait cannot happen, and the task keeps the
    // processor instead of blocking for ever.
    try testing.expect(!scheduler.blockCurrentOn(&queue, &node, 0));
    try testing.expectEqual(State.running, only.state);
    try testing.expectEqual(@as(u32, 0), queue.length());
    try testing.expect(!node.queued);
    try testing.expect(!scheduler.state_lock.isHeld());
    try testing.expectEqual(@as(u64, 0), scheduler.state_lock.refused_releases);
}

test "a wake that arrived before the wait makes the caller look again" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var first_kernel_stack: [1024]u8 align(16) = undefined;
    var second_kernel_stack: [1024]u8 align(16) = undefined;

    const first = scheduler.spawn(noopEntry, stack[0..], first_kernel_stack[0..], 0).?;
    const second = scheduler.spawn(noopEntry, stack[0..], second_kernel_stack[0..], 0).?;
    first.state = .running;
    second.state = .ready;
    scheduler.current[0] = first;

    var queue: wait_queue.WaitQueue = .{};
    var node = wait_queue.Node.init(first, Scheduler.wakeTask);

    // A producer ran before the waiter: the queue remembers the wake.
    try testing.expectEqual(@as(?*wait_queue.Node, null), queue.wakeOne());

    try testing.expect(!scheduler.blockCurrentOn(&queue, &node, 0));
    // The task did not sleep: it has to re-check the condition that the wake
    // was about, and it is still the one on the processor.
    try testing.expectEqual(State.running, first.state);
    try testing.expectEqual(first, scheduler.current[0].?);
    try testing.expectEqual(@as(u32, 0), queue.length());
}

test "a mutex waiter blocks in the scheduler and is handed the lock when it is woken" {
    // The end of the chain that the task subsystem was built for: the mutex
    // queues the waiter in the shared wait queue, the scheduler blocks the task
    // on that queue, and the release of the mutex hands the ownership over and
    // wakes the task through `wakeTask` — which is the same routine that the
    // channel uses for a message.
    const mutex_module = @import("mutex.zig");

    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var holder_kernel_stack: [1024]u8 align(16) = undefined;
    var waiter_kernel_stack: [1024]u8 align(16) = undefined;

    const holder = scheduler.spawn(noopEntry, stack[0..], holder_kernel_stack[0..], 0).?;
    const waiter = scheduler.spawn(noopEntry, stack[0..], waiter_kernel_stack[0..], 0).?;
    holder.state = .ready;
    waiter.state = .running;
    scheduler.current[0] = waiter;

    var mutex: mutex_module.Mutex = .{};
    try testing.expectEqual(mutex_module.Mutex.Take.acquired, mutex.take(holder));
    try testing.expectEqual(mutex_module.Mutex.Take.busy, mutex.take(waiter));

    var node = wait_queue.Node.init(waiter, Scheduler.wakeTask);
    try testing.expectEqual(wait_queue.AddResult.queued, mutex.waitFor(&node));

    // The waiter goes to sleep on the queue of the mutex, and the holder — the
    // only other task — takes the processor.
    try testing.expect(scheduler.blockCurrentOn(&mutex.waiters, &node, 0));
    try testing.expectEqual(State.blocked, waiter.state);
    try testing.expectEqual(holder, scheduler.current[0].?);
    try testing.expectEqual(@as(u32, 1), mutex.waiting());

    // The release transfers the ownership and wakes the waiter, in that order.
    try testing.expectEqual(mutex_module.Mutex.Release.handed_off, mutex.release(holder));
    try testing.expect(mutex.isOwnedBy(waiter));
    try testing.expectEqual(State.ready, waiter.state);
    try testing.expectEqual(@as(u32, 0), mutex.waiting());
    try testing.expectEqual(@as(u32, 1), scheduler.readyCount(0));

    // The woken task runs, finishes its critical section and releases: with
    // nobody in the queue the mutex is free again.
    try testing.expectEqual(mutex_module.Mutex.Release.unlocked, mutex.release(waiter));
    try testing.expect(mutex.isFree());
    try testing.expect(!scheduler.state_lock.isHeld());
}

test "the idle task exists once, and the policy only runs it when nothing else can" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    // The idle task is created by the scheduler itself: no owner, no process,
    // no address space.
    const idle = scheduler.ensureIdle(0).?;
    try testing.expect(idle.is_idle);
    try testing.expectEqual(State.ready, idle.state);
    try testing.expectEqual(policy.idleVruntime, idle.vruntime);
    try testing.expectEqual(@as(u32, 1), scheduler.count);

    // A second call returns the same task instead of creating a second one.
    const again = scheduler.ensureIdle(0).?;
    try testing.expectEqual(idle, again);
    try testing.expectEqual(@as(u32, 1), scheduler.count);

    // A real task is created and made ready: the choice is the real task, even
    // though the idle task is eligible and its runtime is enormous.
    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;
    const worker = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    worker.vruntime = 0;
    worker.state = .ready;

    idle.state = .running;
    scheduler.current[0] = idle;
    try testing.expectEqual(worker, scheduler.findNextReadyForTest(idle).?);

    // With the real task blocked and the idle task on the processor there is
    // nobody to switch to, and the idle task keeps running — halting until the
    // next interrupt is exactly the job. Before the idle task existed this was
    // the case where the scheduler had nothing to return and the processor
    // carried on with whatever the interrupt interrupted.
    worker.state = .blocked;
    try testing.expectEqual(@as(?*Task, null), scheduler.findNextReadyForTest(idle));

    // The other order: a real task runs and the only candidate is the idle
    // task, which is what a blocking call needs in order to sleep at all.
    worker.state = .running;
    idle.state = .ready;
    scheduler.current[0] = worker;
    try testing.expectEqual(idle, scheduler.findNextReadyForTest(worker).?);
}

test "a task that blocks hands the processor to the idle task instead of failing" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    const idle = scheduler.ensureIdle(0).?;

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;
    const worker = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    worker.state = .running;
    worker.quantum = 4;
    scheduler.current[0] = worker;

    // Before the idle task existed this was the "nobody to switch to" case; now
    // there is always somebody, and the wait succeeds.
    var queue: wait_queue.WaitQueue = .{};
    var node = wait_queue.Node.init(worker, Scheduler.wakeTask);
    try testing.expect(scheduler.blockCurrentOn(&queue, &node, 0));
    try testing.expectEqual(State.blocked, worker.state);
    try testing.expectEqual(idle, scheduler.current[0].?);
    try testing.expectEqual(State.running, idle.state);
}

test "a task belongs to one CPU and the other CPU never chooses it" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const here = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    const elsewhere = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;

    // The task of the other CPU is ready, and eligible by every other rule:
    // smaller runtime, not the current one, not blocked, not leaving.
    elsewhere.cpu = 1;
    elsewhere.vruntime = -1000;
    elsewhere.state = .ready;
    here.cpu = 0;
    here.state = .running;
    scheduler.current[0] = here;
    scheduler.current[1] = null;

    // CPU 0 does not see it: choosing it would give one stack and one saved
    // context to two processors.
    try testing.expectEqual(@as(?*Task, null), scheduler.findNextReadyForTest(here));

    // The same task, moved to this CPU, is chosen.
    elsewhere.cpu = 0;
    try testing.expectEqual(elsewhere, scheduler.findNextReadyForTest(here).?);
}

test "the idle task of a CPU is not the last resort of another CPU" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    const idle_of_one = scheduler.ensureIdle(1).?;
    try testing.expectEqual(@as(u8, 1), idle_of_one.cpu);
    try testing.expect(idle_of_one.is_idle);

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;
    const here = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    here.cpu = 0;
    here.state = .running;
    scheduler.current[0] = here;

    // Nothing of CPU 0 can run, and the idle task of CPU 1 is ready: CPU 0 has
    // nobody to switch to, which is the truth. Taking the idle task of the
    // other processor would give it two processors and its own queue none.
    try testing.expectEqual(@as(?*Task, null), scheduler.findNextReadyForTest(here));

    // With its own idle task it has a last resort.
    const idle_of_zero = scheduler.ensureIdle(0).?;
    try testing.expectEqual(@as(u8, 0), idle_of_zero.cpu);
    try testing.expectEqual(idle_of_zero, scheduler.findNextReadyForTest(here).?);
}

test "each CPU has one idle task, and asking twice returns the same one" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    const zero = scheduler.ensureIdle(0).?;
    const one = scheduler.ensureIdle(1).?;

    try testing.expect(zero != one);
    try testing.expect(zero.is_idle and one.is_idle);
    try testing.expectEqual(@as(u8, 0), zero.cpu);
    try testing.expectEqual(@as(u8, 1), one.cpu);
    try testing.expectEqual(@as(u32, 2), scheduler.count);

    // The stacks are not shared: two idle tasks on one stack would overwrite
    // each other's frames the moment both processors halted.
    try testing.expect(zero.kernel_rsp != one.kernel_rsp);

    try testing.expectEqual(zero, scheduler.ensureIdle(0).?);
    try testing.expectEqual(one, scheduler.ensureIdle(1).?);
    try testing.expectEqual(@as(u32, 2), scheduler.count);

    // A number that the table does not have is clamped to the last CPU
    // instead of indexing outside it.
    const clamped = scheduler.ensureIdle(smp.max_cpus + 4).?;
    try testing.expectEqual(@as(u8, smp.max_cpus - 1), clamped.cpu);
}

test "an AP that enters the scheduler gets a task of its own" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var kernel_stack: [1024]u8 align(16) = undefined;
    const top = @intFromPtr(&kernel_stack) + kernel_stack.len;

    const ap = scheduler.adoptKernelTask(1, top, kernel_stack[0..]).?;
    try testing.expectEqual(@as(u8, 1), ap.cpu);
    try testing.expectEqual(State.running, ap.state);
    try testing.expectEqual(top, ap.kernel_rsp);
    try testing.expectEqual(kernel_code_selector, ap.context.cs);
    try testing.expectEqual(ap, scheduler.current[1].?);
    try testing.expectEqual(@as(u8, 1), scheduler.statisticsOf().entered_cpus);

    // The task of the processor is not in its queue: it is already running,
    // and a queue would offer it to itself.
    try testing.expectEqual(@as(u32, 0), scheduler.readyCount(1));

    // A second entry returns the task that already runs there instead of
    // creating a second one.
    try testing.expectEqual(ap, scheduler.adoptKernelTask(1, top, kernel_stack[0..]).?);
    try testing.expectEqual(@as(u32, 1), scheduler.count);
    try testing.expectEqual(@as(u8, 1), scheduler.statisticsOf().entered_cpus);

    // A CPU number that the table does not have is refused.
    try testing.expectEqual(@as(?*Task, null), scheduler.adoptKernelTask(smp.max_cpus, top, kernel_stack[0..]));

    // With a task of its own, the processor can choose work: a ready task of
    // CPU 1 is a candidate, and the adopted task is the one it leaves.
    var stack: [1024]u8 align(16) = undefined;
    const worker = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    worker.cpu = 1;
    worker.state = .ready;
    try testing.expectEqual(worker, scheduler.findNextReadyForTest(ap).?);
}

test "queueing a task on a CPU makes that CPU its owner" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;
    const task = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    try testing.expectEqual(@as(u8, 0), task.cpu);

    scheduler.enqueueReady(task, 3);
    try testing.expectEqual(@as(u8, 3), task.cpu);
    try testing.expectEqual(@as(u32, 1), scheduler.readyCount(3));
}

test "a reschedule switches to a ready task without moving the quantum or the clock" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    // Each task has its own stacks: the canary of a task lives at the bottom of
    // its kernel stack, and two tasks sharing one would overwrite it.
    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;
    var other_stack: [1024]u8 align(16) = undefined;
    var other_kernel_stack: [1024]u8 align(16) = undefined;

    const running = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    const waiting = scheduler.spawn(noopEntry, other_stack[0..], other_kernel_stack[0..], 0).?;

    running.state = .running;
    running.quantum = 5;
    scheduler.current[0] = running;

    waiting.state = .ready;
    waiting.cpu = 0;
    waiting.vruntime = -500;

    // A tick would leave the task alone: its quantum has not ended, and the
    // clock of the system is the only thing that may count time.
    try testing.expect(!scheduler.tick(0));
    try testing.expectEqual(@as(u64, 1), scheduler.statisticsOf().ticks);

    // A reschedule is not a tick: it does not count time, it does not move the
    // quantum, and it hands the processor to the task that can run.
    try testing.expect(scheduler.rescheduleCurrent());
    try testing.expectEqual(@as(u64, 1), scheduler.statisticsOf().ticks);
    try testing.expectEqual(@as(u64, 1), scheduler.statisticsOf().reschedules);
    try testing.expectEqual(waiting, scheduler.current[0].?);
    try testing.expectEqual(State.running, waiting.state);
    try testing.expectEqual(State.ready, running.state);
    // The tick moved the slice by one and the reschedule did not: four, not
    // three, and not five.
    try testing.expectEqual(@as(u16, 4), running.quantum);
}

test "a reschedule with nothing to run keeps the task and its quantum" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const only = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    only.state = .running;
    only.quantum = 3;
    scheduler.current[0] = only;

    try testing.expect(!scheduler.rescheduleCurrent());
    try testing.expectEqual(only, scheduler.current[0].?);
    try testing.expectEqual(State.running, only.state);
    try testing.expectEqual(@as(u16, 3), only.quantum);
    try testing.expectEqual(@as(u64, 1), scheduler.statisticsOf().reschedules);
}

test "a task moves to another CPU and leaves the queue of the one that had it" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;
    var other_stack: [1024]u8 align(16) = undefined;
    var other_kernel_stack: [1024]u8 align(16) = undefined;

    const moving = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    moving.state = .ready;

    const here = scheduler.spawn(noopEntry, other_stack[0..], other_kernel_stack[0..], 0).?;
    here.state = .running;
    here.cpu = 0;
    scheduler.current[0] = here;

    // CPU 0 chooses it while it belongs to CPU 0.
    try testing.expectEqual(moving, scheduler.findNextReadyForTest(here).?);

    // After the migration the queue of CPU 1 holds it, and CPU 0 cannot see it.
    try testing.expect(scheduler.migrateTo(moving, 1));
    try testing.expectEqual(@as(u8, 1), moving.cpu);
    try testing.expectEqual(@as(?*Task, null), scheduler.findNextReadyForTest(here));

    // A running task is on a processor: it cannot change owner underneath it,
    // and a task that ends is not scheduled again anywhere.
    try testing.expect(!scheduler.migrateTo(here, 1));
    moving.state = .terminated;
    try testing.expect(!scheduler.migrateTo(moving, 0));

    // A number that the table does not have is refused, and asking for the CPU
    // that already owns the task changes nothing.
    moving.state = .ready;
    try testing.expect(!scheduler.migrateTo(moving, smp.max_cpus));
    try testing.expect(!scheduler.migrateTo(moving, 1));
}

test "a wake that lands on another CPU asks for that CPU and does not queue here" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const other = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    other.cpu = 1;
    other.state = .blocked;

    Scheduler.wakeTask(other);

    try testing.expectEqual(State.ready, other.state);
    // The ownership did not change: the task stayed on the CPU that owns it.
    try testing.expectEqual(@as(u8, 1), other.cpu);
    // The host has no APIC and no second processor online, so no IPI was
    // delivered, and the counter of delivered reschedules did not move.
    try testing.expectEqual(@as(u64, 0), scheduler.statisticsOf().wake_reschedules);
}

test "a task that ended gives its slot back, and the slot is used again" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    // The whole life of a machine: a task is created, it ends, and its slot
    // goes back to the pool. Before the reaper existed, `count` only grew and
    // the 33rd task of the life of the machine was a creation that failed,
    // however few tasks existed at that moment.
    var stack: [1024]u8 align(16) = undefined;
    var kernel_stacks: [max_tasks + 1][1024]u8 align(16) = undefined;

    var life: u32 = 0;
    while (life < max_tasks + 1) : (life += 1) {
        const task = scheduler.spawn(noopEntry, stack[0..], kernel_stacks[life][0..], 0) orelse
            return error.NoSlot;
        // The task ends as the switch ends it: terminated, and no processor is
        // running it (the host never switches, so nobody is in `current`).
        task.state = .terminated;
        scheduler.requestReap(task);
        try testing.expectEqual(@as(u32, 1), scheduler.statisticsOf().pending_reap);
        try testing.expectEqual(@as(u32, 1), scheduler.reap());
        try testing.expectEqual(@as(u32, 0), scheduler.statisticsOf().pending_reap);
    }

    // One slot existed at a time, and the report says so.
    try testing.expectEqual(@as(u32, 0), scheduler.statisticsOf().tasks);
    try testing.expectEqual(@as(u64, max_tasks + 1), scheduler.statisticsOf().reaped);
}

test "the slot of a task that a processor runs is not collected" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var kernel_stack: [1024]u8 align(16) = undefined;

    const task = scheduler.spawn(noopEntry, stack[0..], kernel_stack[0..], 0).?;
    task.state = .running;
    scheduler.current[0] = task;

    scheduler.terminateCurrent(7);

    // The task is terminated and asks to be collected, but the processor still
    // holds it: its frame is on that stack, and the slot cannot become another
    // task while the processor is about to return into it.
    try testing.expectEqual(State.terminated, task.state);
    try testing.expectEqual(@as(u64, 7), task.exit_code);
    try testing.expectEqual(@as(u32, 1), scheduler.statisticsOf().pending_reap);
    try testing.expectEqual(@as(u32, 0), scheduler.reap());
    try testing.expectEqual(@as(u32, 1), scheduler.statisticsOf().tasks);

    // The processor leaves it, and the next collection takes it.
    scheduler.current[0] = null;
    try testing.expectEqual(@as(u32, 1), scheduler.reap());
    try testing.expectEqual(@as(u32, 0), scheduler.statisticsOf().tasks);
    try testing.expect(!task.reap_queued);
}

test "a tick collects the tasks that ended" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var first_stack: [1024]u8 align(16) = undefined;
    var second_stack: [1024]u8 align(16) = undefined;

    const survivor = scheduler.spawn(noopEntry, stack[0..], first_stack[0..], 0).?;
    survivor.state = .running;
    survivor.quantum = 4;
    scheduler.current[0] = survivor;

    const ending = scheduler.spawn(noopEntry, stack[0..], second_stack[0..], 0).?;
    ending.state = .terminated;
    scheduler.requestReap(ending);

    // The clock is the context that collects: nobody else is running the code
    // of the task that ended.
    _ = scheduler.tick(0);
    try testing.expectEqual(@as(u32, 0), scheduler.statisticsOf().pending_reap);

    // The task that ends twice enters the list once; the second request is a
    // no-op, and the identifier of the collected task is never reused.
    scheduler.requestReap(ending);
    try testing.expectEqual(@as(u32, 0), scheduler.statisticsOf().pending_reap);
}

test "the idle task is never collected" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    const idle = scheduler.ensureIdle(0).?;
    idle.state = .terminated;
    scheduler.requestReap(idle);

    // The last resort of a processor has to exist for as long as the processor
    // does: collecting it would leave the queue with nothing to choose on the
    // first tick that found nothing else.
    try testing.expectEqual(@as(u32, 0), scheduler.statisticsOf().pending_reap);
    try testing.expectEqual(@as(u32, 0), scheduler.reap());
    try testing.expectEqual(@as(u32, 1), scheduler.statisticsOf().tasks);
}

test "the queue never hands out a task that ended" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var first_stack: [1024]u8 align(16) = undefined;
    var second_stack: [1024]u8 align(16) = undefined;

    // A wake enqueues a task that ends before the processor chooses it: the
    // queue keeps the pointer, and the choice has to skip it instead of
    // returning a task that no longer runs.
    const ending = scheduler.spawn(noopEntry, stack[0..], first_stack[0..], 0).?;
    const alive = scheduler.spawn(noopEntry, stack[0..], second_stack[0..], 0).?;

    scheduler.enqueueReady(ending, 0);
    scheduler.enqueueReady(alive, 0);
    ending.state = .terminated;

    try testing.expectEqual(alive, scheduler.dequeueReady(0).?);
    try testing.expectEqual(@as(u32, 0), scheduler.readyCount(0));
}

test "an identifier is not reused when a slot goes back to the pool" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var first_stack: [1024]u8 align(16) = undefined;
    var second_stack: [1024]u8 align(16) = undefined;

    const first = scheduler.spawn(noopEntry, stack[0..], first_stack[0..], 0).?;
    const first_id = first.id;
    first.state = .terminated;
    scheduler.requestReap(first);
    _ = scheduler.reap();

    const second = scheduler.spawn(noopEntry, stack[0..], second_stack[0..], 0).?;

    // The storage is the same, because the slot went back to the pool, and the
    // identity is not: a caller that kept the identifier of the task that ended
    // would otherwise act on the task that received the slot. The identity of a
    // task is therefore its identifier, and never its address.
    try testing.expectEqual(first, second);
    try testing.expectEqual(first_id + 1, second.id);
    try testing.expect(second.state == .ready);
    try testing.expect(!second.reap_queued);
}

test "a slot that goes back to the pool leaves no queue pointing at it" {
    resetSchedulerForTest();
    defer resetSchedulerForTest();

    var stack: [1024]u8 align(16) = undefined;
    var first_stack: [1024]u8 align(16) = undefined;
    var second_stack: [1024]u8 align(16) = undefined;

    const ending = scheduler.spawn(noopEntry, stack[0..], first_stack[0..], 0).?;
    const survivor = scheduler.spawn(noopEntry, stack[0..], second_stack[0..], 0).?;

    // A wake enqueued the task that is now ending. The queue keeps the
    // pointer, and the pointer is what the slot becomes when it is handed out
    // again: an entry that stayed would make the new task run twice.
    scheduler.enqueueReady(ending, 0);
    scheduler.enqueueReady(survivor, 0);
    ending.state = .terminated;
    scheduler.requestReap(ending);

    try testing.expectEqual(@as(u32, 1), scheduler.reap());
    try testing.expectEqual(@as(u32, 1), scheduler.readyCount(0));

    const replacement = scheduler.spawn(noopEntry, stack[0..], first_stack[0..], 0).?;
    try testing.expectEqual(replacement, ending);

    // The queue holds the survivor once and the replacement never.
    try testing.expectEqual(survivor, scheduler.dequeueReady(0).?);
    try testing.expectEqual(@as(u32, 0), scheduler.readyCount(0));
}
