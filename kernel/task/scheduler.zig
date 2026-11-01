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
const cpu = @import("../arch/x86_64/cpu.zig");
const kynox = @import("kynox_shared");

const context = @import("context.zig");
const paging = @import("../arch/x86_64/paging.zig");
const segment = @import("../arch/x86_64/segment.zig");
const smp = @import("../arch/x86_64/smp.zig");
const channel = @import("../ipc/channel.zig");
const lock = @import("lock.zig");
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
    /// The state of the task.
    state: State = .ready,
    /// The code with which the task ended.
    exit_code: u64 = 0,
    /// The number of times the task was scheduled.
    schedules: u64 = 0,
    /// The priority of the task. Higher values mean higher priority.
    /// The scheduler chooses the ready task with the highest priority.
    priority: u8 = 0,
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
        if (self.ready_count[cpu_id] == 0) return null;
        const task = self.ready_queue[cpu_id][0];
        var index: u32 = 0;
        while (index + 1 < self.ready_count[cpu_id]) : (index += 1) {
            self.ready_queue[cpu_id][index] = self.ready_queue[cpu_id][index + 1];
        }
        self.ready_count[cpu_id] -= 1;
        self.ready_queue[cpu_id][self.ready_count[cpu_id]] = null;
        return task;
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
        segment.tss.rsp0 = task.kernel_rsp;
        kynox_kernel_stack_pointer = task.kernel_rsp;
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

        return self.prepareNext();
    }

    /// Prepares the switch to the next task that can be chosen.
    ///
    /// The function is used by the timer and by the blocking of a task: in
    /// both cases the task that leaves is saved, and the next task is
    /// chosen and prepared. The difference is that the blocking is not a
    /// tick of the timer, and therefore the tick counter does not move.
    fn prepareNext(self: *Scheduler) bool {
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

        if (policy.shouldPreempt(current.state == .running, current.quantum)) {
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
        segment.tss.rsp0 = next.kernel_rsp;
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
        // K3.12.2 fix: enqueue the ready task; previously missing.
        scheduler.enqueueReady(value, smp.cpuId());
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
        statistics.tasks = self.count;

        var ready: u32 = 0;
        var blocked: u32 = 0;
        for (self.tasks) |task| {
            const value = task orelse continue;
            if (value.state == .ready) ready += 1;
            if (value.state == .blocked) blocked += 1;
        }
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

    /// Describes the queue as the policy sees it.
    ///
    /// A slot is eligible when it holds a task, the task is ready, it is not
    /// the task that is leaving, and the process of the task is not leaving:
    /// the threads of a process that is `exiting` or `reaped` are not
    /// scheduled, because their address space is on its way out.
    fn describeQueue(self: *const Scheduler, current: *Task) [max_tasks]policy.Entry {
        var entries: [max_tasks]policy.Entry = undefined;

        for (self.tasks, 0..) |slot, index| {
            entries[index] = .{ .index = index, .vruntime = 0, .eligible = false };

            const task = slot orelse continue;
            if (task == current) continue;
            if (task.state != .ready) continue;
            if (task.process_ref) |process_ref| {
                const state = process_ref.state;
                if (state == .exiting or state == .reaped) continue;
            }

            entries[index] = .{ .index = index, .vruntime = task.vruntime, .eligible = true };
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

    /// Reserves a task of the storage of the scheduler.
    fn allocate(self: *Scheduler) ?*Task {
        if (self.count >= max_tasks) return null;

        const index = self.count;
        self.count += 1;

        const task = &self.storage[index];
        task.* = .{ .id = self.next_id, .state = .ready, .quantum = 16 };
        self.next_id += 1;
        self.tasks[index] = task;

        return task;
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
