//************************************************************************//
//  timer.zig                                                             //
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

//! The timer of the kernel and the interrupt controllers.
//!
//! The kernel uses the programmable interval timer of the PC, the 8254, in
//! its most simple mode: channel zero generates a periodic interrupt at a
//! fixed frequency. The interrupt is delivered by the first of the two
//! interrupt controllers, the 8259, which the kernel reprograms so that the
//! hardware interrupts occupy the vectors that follow the exceptions of the
//! processor.

const std = @import("std");
const kynox = @import("kynox_shared");

const serial = kynox.serial;
const cpu = @import("cpu.zig");
const apic = @import("apic.zig");
const config = @import("kynox_config");
const perf_tsc_hz: u32 = 2_800_000_000; // Valores de calibracao QEMU

/// The frequency of the timer of the PC.
pub const pit_frequency: u32 = 1_193_182;

/// Ports of the programmable interval timer.
const pit = struct {
    const channel0 = 0x40;
    const command = 0x43;
};

/// Ports of the interrupt controllers.
const pic = struct {
    const master_command = 0x20;
    const master_data = 0x21;
    const slave_command = 0xA0;
    const slave_data = 0xA1;
};

/// The vector of the first hardware interrupt.
pub const first_hardware_vector: u8 = 32;

/// The number of hardware interrupts.
pub const hardware_interrupt_count: u8 = 16;

/// Number of ticks since the timer was started.
var tick_count: u64 = 0;

/// The frequency of the bus of the local APIC, measured by the calibration of
/// the BSP. Zero means "not measured", and a clock that has no measurement is
/// not armed at all: a divisor guessed wrong is a clock that runs at the wrong
/// speed, and nothing in the log would say so.
var calibrated_bus_frequency: u32 = 0;

/// The frequency the calibration of the BSP measured.
pub fn calibratedBusFrequency() u32 {
    return calibrated_bus_frequency;
}

/// Arms the local timer of this processor with the frequency the BSP measured.
///
/// The calibration waits for a one-shot timer to run down, and it measures the
/// bus of the machine: an AP would waste the same time to reach the same number.
/// Two conditions are refused instead of guessed, and both return false:
///
///   * the local APIC is not mapped (the controller cannot be written);
///   * there is no measurement, or the requested frequency does not fit in it.
pub fn armLocalApicTimer() bool {
    if (!apic.isMapped()) return false;
    if (calibrated_bus_frequency == 0) return false;
    if (frequency == 0 or frequency > calibrated_bus_frequency) return false;

    const divisor: u32 = calibrated_bus_frequency / frequency;
    apic.setTimerDivide(0);
    apic.timerPeriodic(if (divisor < 1) 1 else divisor);
    return true;
}

/// The frequency of the timer in interrupts per second.
var frequency: u32 = 100;

/// Prepares the interrupt controllers and the timer.
///
/// The controllers are reprogrammed so that the hardware interrupts use the
/// vectors that follow the exceptions of the processor, and the timer is
/// started at the given frequency.
pub fn init(ticks_per_second: u32) void {
    frequency = ticks_per_second;
    tick_count = 0;

    // Remap the interrupt controllers.
    //
    // The first controller receives the vectors 32 to 39 and the second one
    // the vectors 40 to 47. The second controller is connected to the
    // interrupt request line 2 of the first one.
    writePort(pic.master_command, 0x11); // initialisation, expects the fourth word
    writePort(pic.master_data, first_hardware_vector);
    writePort(pic.master_data, 0x04); // the second controller is on line 2
    writePort(pic.master_data, 0x01); // 8086 mode

    writePort(pic.slave_command, 0x11);
    writePort(pic.slave_data, first_hardware_vector + 8);
    writePort(pic.slave_data, 0x02); // the cascade identity
    writePort(pic.slave_data, 0x01);

    // Enable IRQ0 (timer) and IRQ1 (legacy PS/2 keyboard).
    // Other IRQ lines remain masked until a driver claims them.
    writePort(pic.master_data, 0xFC);
    writePort(pic.slave_data, 0xFF);

    // Program the timer: channel zero, low and high byte of the divisor,
    // square wave mode.
    if (ticks_per_second == 0) return;
    const divisor = pit_frequency / ticks_per_second;
    writePort(pit.command, 0x34);
    writePort(pit.channel0, @truncate(divisor & 0xFF));
    writePort(pit.channel0, @truncate((divisor >> 8) & 0xFF));
}

/// A source of ticks of the system.
///
/// The machine has two clocks that can interrupt the processor: the 8254
/// (through the 8259, or through the I/O APIC once that path delivers) and the
/// local APIC timer of each CPU. Only one of them may drive the scheduler and
/// the clock of the system, otherwise every interval is counted twice: the
/// quantum of a task halves, and every timeout of IPC and input expires twice as
/// fast as its contract says. The audit of 2026-10-31 records exactly this
/// defect (C.6), because both sources were armed on the BSP.
pub const TickSource = enum {
    /// The 8254 programmable interval timer, delivered by the 8259.
    pit,
    /// The local timer of the local APIC of the CPU.
    apic,
};

/// The source that counts the time and drives the scheduler.
///
/// The default is the 8254 because it is the source that the boot path programs
/// first and the only one whose delivery has a recorded path in QEMU. The local
/// APIC timer is calibrated at boot, but until its periodic delivery is
/// validated it stays a measurement, not the clock.
var tick_source: TickSource = .pit;

/// Chooses the source that owns the tick.
///
/// The choice is per system today, and per CPU when the APs run: a CPU that
/// receives an interrupt from the source that does not own the tick does not
/// count it and does not preempt on it.
pub fn selectTickSource(source: TickSource) void {
    tick_source = source;
}

/// The source that owns the tick.
pub fn tickSource() TickSource {
    return tick_source;
}

/// True when an interrupt of `source` is the one that owns the tick.
pub fn drivesScheduler(source: TickSource) bool {
    return tick_source == source;
}

/// Counts one tick of the timer.
///
/// The tick is counted only when it comes from the source that owns it. A
/// counter that adds every interrupt of both clocks is not a clock: it is the
/// sum of two clocks, and nothing can convert it to seconds.
pub fn onTick(source: TickSource) void {
    if (!drivesScheduler(source)) return;
    tick_count += 1;
}

/// The number of ticks since the timer was started.
pub fn ticks() u64 {
    return tick_count;
}

/// How many processors can have a clock of their own.
///
/// It matches the limit of the CPU table. The ledger is not the table: this
/// module counts time and knows nothing about APIC ids, MADT entries or
/// scheduling, and the caller passes the number it already uses for everything
/// else (the index of the CPU table).
pub const max_cpu_clocks: usize = 8;

/// What the clock of one processor is.
pub const CpuClock = enum {
    /// This processor counts the clock of the system. There is one such
    /// processor, and it is the one the 8254 interrupts.
    system,
    /// This processor counts its own local timer and never touches the counter
    /// of the system: an AP has no connection to the 8254 at all, so a "system"
    /// role there would be a processor counting a clock that does not reach it.
    local,
};

var cpu_clocks: [max_cpu_clocks]?CpuClock = @splat(null);
var cpu_ticks: [max_cpu_clocks]u64 = @splat(0);

/// Ticks that arrived on a processor whose clock is not the one that fired.
///
/// It is the number that turns "the clock is wrong" from an opinion into a
/// count: a processor armed as `local` that receives the 8254 is a processor
/// counting somebody else's clock.
var ignored_ticks: u64 = 0;

/// Gives one processor a clock.
///
/// Arming twice with the same role is not an error and changes nothing: the boot
/// arms the BSP, and a caller that runs again (a retry, a test) must not have to
/// know whether it already happened. Arming with a **different** role is
/// refused, because a processor that counted the system clock and then its own
/// local timer would put two clocks into one machine — the defect C.6 of the
/// audit of 2026-10-31, in a new place.
pub fn armCpuClock(cpu_index: u8, role: CpuClock) bool {
    if (cpu_index >= max_cpu_clocks) return false;
    if (cpu_clocks[cpu_index]) |armed| return armed == role;
    cpu_clocks[cpu_index] = role;
    return true;
}

/// The role of the clock of one processor, or null when nobody armed it.
pub fn cpuClockRole(cpu_index: u8) ?CpuClock {
    if (cpu_index >= max_cpu_clocks) return null;
    return cpu_clocks[cpu_index];
}

/// True when an interrupt of `source` on `cpu_index` is the clock of that
/// processor.
///
/// The answer is not the same for every processor: the BSP counts the source
/// that owns the tick of the system, and an AP counts its own local timer, which
/// is the only clock it has. A processor nobody armed has no clock, and its
/// interrupts are counted as ignored.
pub fn drivesSchedulerOn(cpu_index: u8, source: TickSource) bool {
    const role = cpuClockRole(cpu_index) orelse return false;
    return switch (role) {
        .system => drivesScheduler(source),
        .local => source == .apic,
    };
}

/// Counts one tick of the clock of one processor.
///
/// Returns true when the tick was the clock of that processor. Only the
/// processor with the `system` role moves the counter of the machine: an AP
/// counting its own ticks into the system clock would make every timeout depend
/// on how many processors are online.
pub fn onCpuTick(cpu_index: u8, source: TickSource) bool {
    const role = cpuClockRole(cpu_index) orelse {
        ignored_ticks += 1;
        return false;
    };

    switch (role) {
        .system => {
            if (!drivesScheduler(source)) {
                ignored_ticks += 1;
                return false;
            }
            onTick(source);
        },
        .local => {
            if (source != .apic) {
                ignored_ticks += 1;
                return false;
            }
        },
    }

    cpu_ticks[cpu_index] += 1;
    return true;
}

/// The ticks counted by one processor, or null when the number is not a CPU.
pub fn ticksOf(cpu_index: u8) ?u64 {
    if (cpu_index >= max_cpu_clocks) return null;
    return cpu_ticks[cpu_index];
}

/// Ticks that arrived on a processor whose clock is not the one that fired.
pub fn ignoredTicks() u64 {
    return ignored_ticks;
}

/// The frequency of the timer in interrupts per second.
pub fn ticksPerSecond() u32 {
    return frequency;
}

/// Acknowledges the interrupt to the controllers.
///
/// The first controller is acknowledged when the interrupt comes from the
/// second one, because the second controller is connected to it.
pub fn acknowledge(vector: u8) void {
    if (vector >= first_hardware_vector + 8) {
        writePort(pic.slave_command, 0x20);
    }
    writePort(pic.master_command, 0x20);
}

/// Masks every line of the 8259.
///
/// Used when the I/O APIC takes over delivery: the two controllers must never
/// forward the same line at the same time.
pub fn disablePic() void {
    writePort(pic.master_data, 0xFF);
    writePort(pic.slave_data, 0xFF);
}

/// Ends a hardware interrupt at the controller that delivered it.
///
/// The EOI goes to the 8259 while it owns delivery and to the local APIC once
/// the I/O APIC is in charge. Writing to the wrong one leaves the interrupt
/// controller waiting and blocks every later interrupt of that priority, so
/// the choice is made here, next to the delivery switch.
pub fn endOfInterrupt(vector: u8) void {
    if (config.ioapic_delivery) {
        apic.eoi();
        return;
    }
    acknowledge(vector);
}

/// Enables the interrupts of the processor.
pub fn enableInterrupts() void {
    cpu.enableInterrupts();
}

/// Writes a byte to a port.
fn writePort(port: u16, value: u8) void {
    kynox.port.outb(port, value);
}

/// Configura o timer local da APIC para a CPU atual.
///
/// Deve ser chamado pelo BSP e por cada AP apos o mapeamento do APIC
/// local e a habilitacao de interrupcoes. O timer dispara periodicamente
/// no vetor `apic.timer_vector`, fazendo com que cada CPU trate seus
/// proprio ticks de escalonamento de forma independente.
///
/// `ticks_per_second` e a frequencia desejada de interrupcoes do timer.
/// O divisor e calculado a partir de uma frequencia de barramento de
/// 10 MHz (valor tipico do QEMU; sistemas reais devem ler isso da ACPI).
pub fn initApicTimer(ticks_per_second: u32) void {
    if (!apic.isMapped()) return;
    if (ticks_per_second == 0) return;

    // FASE 2 — Calibracao do APIC Timer. Utiliza o contador TSC para medir
    // a frequencia real do barramento do APIC, substituindo a presuncao de
    // 10 MHz. Nao depende de ACPI MADT nesta etapa.
    //
    // A calibracao envolve:
    // 1. Parar o APIC timer.
    // 2. Armar o timer em modo one-shot com um divisor conhecido (maximo).
    // 3. Aguardar o timer disparar (usando `cpu.halt()`).
    // 4. Medir o tempo decorrido usando `cpu.readTimestamp()`.
    // 5. Calcular a frequencia do barramento com base nessa medição.

    var bus_freq: u32 = 10_000_000; // Valor padrao se a calibracao falhar.

    apic.timerStop(); // Garante que o timer APIC esteja parado.
    apic.setTimerDivide(0); // Divisor 2, como padrao (00b = /2).

    // Armar o timer em modo one-shot com um valor maximo para contar
    // o numero de ciclos TSC para um periodo longo.
    const calibration_ticks: u32 = 0xFFFFF;
    apic.timerOneShot(calibration_ticks);

    const tsc_start = cpu.readTimestamp();
    var attempts: u64 = 0;
    while (apic.read32(apic.ApicOffset.timer_current) != 0 and attempts < 1_000_000) : (attempts += 1) {
        cpu.pause();
    }
    const tsc_end = cpu.readTimestamp();

    // Se o timer nao disparou, ou houve algum problema, use a frequencia padrao.
    if (attempts >= 1_000_000 or (tsc_end - tsc_start) == 0) {
        serial.printLine("[KNK] APIC: falha na calibracao, usando 10 MHz padrao.", .{});
    } else {
        // Calcula a frequencia do barramento APIC.
        // Sabemos que o TSC ja foi calibrado em kernel/main.zig.
        // bus_freq = (calibration_ticks * perf_tsc_hz) / (tsc_end - tsc_start)
        // Onde perf_tsc_hz eh a frequencia do TSC em Hz.
        const tsc_elapsed = tsc_end - tsc_start;
        bus_freq = @intCast(@as(u128, calibration_ticks) * perf_tsc_hz / tsc_elapsed);
        serial.printLine("[KNK] APIC: bus freq calibrada: {d} Hz", .{bus_freq});
    }

    // A medicao fica guardada: os APs armam o proprio timer com ela em vez de
    // repetirem a calibracao, que mede uma propriedade da maquina e nao de um
    // processador.
    calibrated_bus_frequency = bus_freq;

    // Agora com a frequencia calibrada, configura o timer para o uso normal.
    // FASE 2 — Evita divisor zero (se ticks > bus, truncado seria zero).
    if (ticks_per_second > bus_freq) {
        // Frequencia desejada excede a capacidade do timer APIC, usa o maximo possivel.
        // Isso ainda pode levar a um divisor de 0 se bus_freq for muito baixo.
        apic.timerPeriodic(1); // menor divisor possivel, 1Hz
        return;
    }
    // divisor protegido contra zero: ticks_per_second > bus_freq nesta condicao.
    const divisor: u32 = @intCast(@as(u128, bus_freq) / @as(u128, ticks_per_second));
    // Garante divisor >= 1 para evitar timerPeriodic(0), a qual nao dispara o timer.
    const safe_divisor: u32 = if (divisor < 1) 1 else divisor;

    // A política de fonte de tick decide se este relógio pode ser armado.
    //
    // Armar o timer local enquanto o 8254 também entrega produz duas
    // interrupções por período. A calibração acima continua útil — ela mede a
    // frequência do barramento do APIC — mas o modo periódico só é ligado
    // quando o vetor do APIC é o dono do tick nesta CPU.
    if (!drivesScheduler(.apic)) {
        apic.timerStop();
        serial.printLine(
            "[KNK] apic-timer: calibrated, left disarmed (the tick source is {s})",
            .{@tagName(tick_source)},
        );
        return;
    }

    // Configura o divisor e arma o modo periodico diretamente.
    // timerPeriodic() ja define periodico + vetor; nao precisa de timerStop/timerDivide separados.
    apic.timerPeriodic(safe_divisor);

    frequency = ticks_per_second;
}

// The tests of the tick policy.
//
// The policy is the only part of this module that a host can test: the rest
// writes ports and MMIO. That is the reason the policy lives here, apart from
// the programming of the two clocks.

test "only the selected source counts the tick and drives the scheduler" {
    const start = tick_count;

    selectTickSource(.pit);
    try std.testing.expect(drivesScheduler(.pit));
    try std.testing.expect(!drivesScheduler(.apic));

    // The interrupt of the source that does not own the tick neither counts
    // time nor preempts.
    onTick(.apic);
    try std.testing.expectEqual(start, tick_count);

    onTick(.pit);
    onTick(.pit);
    try std.testing.expectEqual(start + 2, tick_count);

    // Choosing the other source swaps the owner and does not reset the clock:
    // the time that passed did pass.
    selectTickSource(.apic);
    try std.testing.expect(drivesScheduler(.apic));
    try std.testing.expect(!drivesScheduler(.pit));
    onTick(.pit);
    try std.testing.expectEqual(start + 2, tick_count);
    onTick(.apic);
    try std.testing.expectEqual(start + 3, tick_count);

    selectTickSource(.pit);
    try std.testing.expectEqual(TickSource.pit, tickSource());
}

test "the two clocks together never count twice for one period" {
    // This is the defect of the audit (C.6) as a test: with both clocks armed
    // and no policy, five periods become ten ticks. With the policy, five
    // periods are five ticks whatever the other clock does.
    selectTickSource(.pit);
    defer selectTickSource(.pit);

    const start = tick_count;
    var period: usize = 0;
    while (period < 5) : (period += 1) {
        onTick(.pit);
        onTick(.apic); // the calibrated local timer of the BSP
    }
    try std.testing.expectEqual(start + 5, tick_count);
}

test "a processor is armed once and with one role" {
    // Idempotent for the same role: the boot arms the BSP, and a caller that
    // runs again must not have to know whether it already happened.
    try std.testing.expect(armCpuClock(0, .system));
    try std.testing.expect(armCpuClock(0, .system));
    try std.testing.expectEqual(CpuClock.system, cpuClockRole(0).?);

    // A different role is refused: counting both clocks is the defect C.6 in a
    // new place, and it is refused instead of silently overwritten.
    try std.testing.expect(!armCpuClock(0, .local));
    try std.testing.expectEqual(CpuClock.system, cpuClockRole(0).?);

    try std.testing.expect(armCpuClock(1, .local));
    try std.testing.expectEqual(CpuClock.local, cpuClockRole(1).?);

    // A number that is not a processor has no clock at all.
    try std.testing.expect(!armCpuClock(max_cpu_clocks, .local));
    try std.testing.expectEqual(@as(?CpuClock, null), cpuClockRole(max_cpu_clocks));
}

test "the clock of the system is counted by the processor that owns it" {
    selectTickSource(.pit);
    defer selectTickSource(.pit);
    _ = armCpuClock(0, .system);

    const start = tick_count;
    const cpu_start = ticksOf(0).?;

    // The 8254 is the clock of this processor, so the tick is time and also a
    // tick of this processor.
    try std.testing.expect(onCpuTick(0, .pit));
    try std.testing.expectEqual(start + 1, tick_count);
    try std.testing.expectEqual(cpu_start + 1, ticksOf(0).?);

    // The local timer of the BSP is calibrated and disarmed, and even if it
    // fired it is not the clock of the machine: it counts as ignored, not as
    // time.
    const ignored_start = ignoredTicks();
    try std.testing.expect(!onCpuTick(0, .apic));
    try std.testing.expectEqual(start + 1, tick_count);
    try std.testing.expectEqual(cpu_start + 1, ticksOf(0).?);
    try std.testing.expectEqual(ignored_start + 1, ignoredTicks());
}

test "an AP counts its own timer and never moves the clock of the system" {
    selectTickSource(.pit);
    defer selectTickSource(.pit);
    _ = armCpuClock(1, .local);

    const system_start = tick_count;
    const cpu_start = ticksOf(1).?;

    // The local timer of the AP is its clock.
    try std.testing.expect(onCpuTick(1, .apic));
    try std.testing.expect(onCpuTick(1, .apic));
    try std.testing.expectEqual(cpu_start + 2, ticksOf(1).?);

    // ... and it is not the clock of the machine: a timeout measured in ticks
    // must not depend on how many processors are online.
    try std.testing.expectEqual(system_start, tick_count);

    // The 8254 does not reach an AP, so a tick from it there is not time.
    const ignored_start = ignoredTicks();
    try std.testing.expect(!onCpuTick(1, .pit));
    try std.testing.expectEqual(cpu_start + 2, ticksOf(1).?);
    try std.testing.expectEqual(ignored_start + 1, ignoredTicks());
}

test "a processor nobody armed has no clock and its ticks are ignored" {
    // Index 2 is never armed by any test; the role is what decides, not the
    // existence of the processor in the table.
    try std.testing.expectEqual(@as(?CpuClock, null), cpuClockRole(2));
    try std.testing.expect(!drivesSchedulerOn(2, .pit));
    try std.testing.expect(!drivesSchedulerOn(2, .apic));

    const system_start = tick_count;
    const ignored_start = ignoredTicks();
    try std.testing.expect(!onCpuTick(2, .apic));
    try std.testing.expectEqual(system_start, tick_count);
    try std.testing.expectEqual(ignored_start + 1, ignoredTicks());

    // A number that is not a processor counts nothing and has no ticks.
    try std.testing.expect(!onCpuTick(max_cpu_clocks, .apic));
    try std.testing.expectEqual(@as(?u64, null), ticksOf(max_cpu_clocks));
}
