//************************************************************************//
//  apic.zig                                                              //
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

//! APIC local (xAPIC): registradores de mapeamento de memoria do
//! Advanced Programmable Interrupt Controller.
//!
//! Este modulo estabelece o acesso ao APIC local de cada CPU logica:
//! registradores de identificacao, tarefa de prioridade, registro de fim
//! de interrupcao, timer local, erros e comandos inter-processador (ICR).
//!
//! O endereco base do APIC local **nao** e mais fixo. O kernel le a MADT
//! da ACPI durante o boot (antes de trocar as tabelas de pagina) e chama
//! `setBase` com o endereco que o firmware publicou; quando a tabela nao
//! existe, esta corrompida ou traz um valor invalido, o kernel registra o
//! motivo e usa `default_base`, que e o endereco tipico de sistemas
//! reais e o que o QEMU/OVMF publica.
//!
//! O acesso ao APIC local e feito por memoria mapeada. Cada registro tem
//! 4 bytes mas esta espacado a cada 16 bytes (espacamento 16 bytes entre
//! registros de 4 bytes).

const std = @import("std");
const cpu = @import("cpu.zig");
// The APIC does not import the timer: the timer programs the local timer
// through this module, and the import that used to be here was unused and
// closed a cycle (apic <-> timer, audit defect 7).

/// Endereco base padrao do APIC local (mapeamento de memoria).
///
/// Usado apenas como fallback: o caminho normal e o endereco lido da MADT
/// pela descoberta de `kernel/main.zig` e instalado por `setBase`.
pub const default_base: u64 = 0xFEE00000;

/// Erros da instalacao do endereco base.
pub const ConfigureError = error{
    /// O endereco e zero: nao existe APIC na pagina zero.
    NullAddress,
    /// O endereco nao esta alinhado a uma pagina.
    Misaligned,
    /// O endereco esta fora do mapeamento identidade do firmware.
    OutOfRange,
};

/// Tamanho de pagina usado para validar o alinhamento.
const page_size: u64 = 4096;

/// Limite do mapeamento identidade, em bytes (primeiros 4 GiB).
const identity_mapped_limit: u64 = 4 * 1024 * 1024 * 1024;

/// Verdadeiro quando `address` pode ser usado como base do APIC local.
///
/// A funcao e pura e existe para que o teste cubra os mesmos criterios que
/// `setBase` aplica.
pub fn isValidBase(address: u64) bool {
    if (address == 0) return false;
    if (address % page_size != 0) return false;
    return address < identity_mapped_limit;
}

/// Endereco base em uso. Comeca no valor padrao e e trocado por
/// `setBase` depois da descoberta da ACPI.
var base_address: u64 = default_base;

/// Instala o endereco base vindo da ACPI.
///
/// A validacao acontece aqui, e nao no chamador: um valor invalido nunca
/// chega a ser usado como ponteiro de MMIO.
pub fn setBase(address: u64) ConfigureError!void {
    if (address == 0) return error.NullAddress;
    if (address % page_size != 0) return error.Misaligned;
    if (address >= identity_mapped_limit) return error.OutOfRange;
    base_address = address;
}

/// Endereco base em uso pelo kernel.
pub fn baseAddress() u64 {
    return base_address;
}

/// Volta ao endereco padrao; usado quando a descoberta falha.
pub fn resetBase() void {
    base_address = default_base;
}

/// Offset dos registradores do APIC local, em bytes, a partir da base.
/// Cada registro de 32 bits ocupa 16 bytes (espacamento de 16).
pub const ApicOffset = struct {
    /// ID da APIC local (apenas o byte mais significativo importa).
    pub const id: u64 = 0x020;
    /// Versao da APIC local.
    pub const version: u64 = 0x030;
    /// Prioridade de tarefa (TPR): mascara interrupcoes abaixo do limiar.
    pub const tpr: u64 = 0x080;
    /// Prioridade de arbitragem (APR).
    pub const apr: u64 = 0x090;
    /// Prioridade do processador (PPR).
    pub const ppr: u64 = 0x0a0;
    /// Endereco de destino do EOI.
    pub const eoi: u64 = 0x0b0;
    /// Registrador de detector logico (LDR).
    pub const ldr: u64 = 0x0d0;
    /// Formato de destino (DFR).
    pub const dfr: u64 = 0x0e0;
    /// Vetor de interrupcao spuria (SVR): habilita a APIC e define o vetor.
    pub const svr: u64 = 0x0f0;
    /// Registro de erro (ESR).
    pub const esr: u64 = 0x280;
    /// Timer: contagem inicial (ICR).
    pub const timer_icr: u64 = 0x320;
    /// Timer: configuracao e vetor (TDR).
    pub const timer_config: u64 = 0x330;
    /// Timer: contador atual.
    pub const timer_current: u64 = 0x340;
    /// Interrupcao local 0 (LINT0).
    pub const lint0: u64 = 0x350;
    /// Interrupcao local 1 (LINT1).
    pub const lint1: u64 = 0x360;
    /// Registrador de erro (ESR).
    pub const error_reg: u64 = 0x370;
    /// Timer: divisor de frequencia (TDR / divide).
    pub const timer_divide: u64 = 0x3E0;
    /// ICR baixo (comando de interrupcao inter-processador).
    pub const icr_low: u64 = 0x300;
    /// ICR alto (destino da IPI).
    pub const icr_high: u64 = 0x310;
};

/// Bits do SVR (Spurious Interrupt Vector Register).
pub const SvrBits = struct {
    /// Habilita a APIC local.
    pub const apic_enabled: u32 = 1 << 8;
    /// Vetor de interrupcao spuria (bits 0-7).
    pub const spurious_vector_mask: u32 = 0xFF;
};

/// Tipos de comando da ICR (bits 8-10 do ICR baixo).
pub const IcrDeliveryMode = enum(u32) {
    fixed = 0x000,
    lowest_priority = 0x100,
    smi = 0x200,
    nmi = 0x400,
    init = 0x500,
    startup = 0x600,
};

/// Modo de nivel da ICR (bit 14 do ICR baixo).
pub const IcrLevel = enum(u32) {
    deassert = 0x000,
    assert = 0x400,
};

/// Modo de trigger da ICR (bit 15 do ICR baixo).
pub const IcrTriggerMode = enum(u32) {
    edge = 0x000,
    level = 0x800,
};

/// Destino da IPI (bits 17-18 do ICR baixo).
pub const IcrDestinationMode = enum(u32) {
    physical = 0x000,
    logical = 0x100,
};

/// Estados de execucao da IPI (shorthand de destino, bits 17-18 do ICR baixo).
pub const IcrDestinationShorthand = enum(u32) {
    none = 0x000,
    self = 0x200,
    all_including_self = 0x400,
    all_excluding_self = 0x600,
};

/// Estado de delivery pendente da ICR (bit 12 do ICR baixo).
pub const IcrDeliveryStatus = enum(u32) {
    idle = 0x000,
    pending = 0x100,
};

/// Vetor da interrupcao do timer local do APIC.
// Alinhado com INTERRUPT_ENTRY 64 no assembly de interrupcao.
pub const timer_vector: u32 = 64;

/// Acesso ao APIC local como ponteiro para a regiao mapeada de memoria.
///
/// Antes de `map` o ponteiro aponta para a base padrao, nunca para um valor
/// indefinido: `isMapped` consulta `mapped` e nenhum leitor de registrador
/// roda antes disso, mas um ponteiro indefinido seria comportamento
/// indefinido mesmo sem ser lido.
var apic: [*]u8 = @ptrFromInt(@as(usize, default_base));

/// O APIC local foi registrado por `map`.
var mapped: bool = false;

/// Mapeia o APIC local na regiao de memoria do kernel.
///
/// O caller deve ja ter mapeado a pagina fisica do APIC no espaco de
/// enderecos do kernel e passar o endereco virtual. Esta funcao apenas
/// registra o ponteiro para acesso aos registradores.
pub fn map(base: u64) void {
    apic = @ptrFromInt(@as(usize, base));
    mapped = true;
}

/// Esquece o mapeamento registrado (usado pelos testes e pelo desligamento).
pub fn unmap() void {
    apic = @ptrFromInt(@as(usize, default_base));
    mapped = false;
}

/// Retorna true se o APIC local foi mapeado.
pub fn isMapped() bool {
    return mapped;
}

/// Le um registrador de 32 bits do APIC local.
pub fn read32(offset: u64) u32 {
    const addr = @intFromPtr(apic) + offset;
    const ptr: *u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Escreve um valor de 32 bits em um registrador do APIC local.
fn write32(offset: u64, value: u32) void {
    const addr = @intFromPtr(apic) + offset;
    const ptr: *u32 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Le o ID da APIC local.
///
/// O ID esta no byte mais significativo do registrador de ID.
pub fn readApicId() u32 {
    // O ID de APIC local do xAPIC tem 8 bits; o restante do registrador nao e
    // o identificador. A mascara evita que um byte alto qualquer chegue ao
    // campo de destino de uma entrada do I/O APIC, que tambem tem 8 bits.
    return (read32(ApicOffset.id) >> 24) & 0xFF;
}

/// Le a versao da APIC local.
pub fn readApicVersion() u32 {
    return read32(ApicOffset.version) & 0xFF;
}

/// Habilita a APIC local definindo o bit de habilitacao do SVR.
///
/// O vetor de interrupcao spuria fica definido como 0xFF (ignorado).
pub fn enable() void {
    const svr = read32(ApicOffset.svr);
    write32(ApicOffset.svr, svr | SvrBits.apic_enabled);
}

/// Envia o sinal de fim de interrupcao (EOI) ao APIC local.
///
/// O EOI deve ser chamado ao final do tratamento de uma interrupcao
/// recebida pelo APIC local para que ele possa entregar a proxima.
pub fn eoi() void {
    write32(ApicOffset.eoi, 0);
}

/// Define o limiar de prioridade de tarefa (TPR).
///
/// Interrupcoes com prioridade menor ou igual ao limiar sao mascaradas.
/// Escrever zero permite todas as interrupcoes gerenciadas pela APIC.
pub fn setTpr(priority: u32) void {
    write32(ApicOffset.tpr, priority & 0xFF);
}

/// Configura o timer local da APIC no modo one-shot.
///
/// `divisor` divide o frequencia do barramento do timer (tipicamente
/// 10 MHz em QEMU). O timer dispara o vetor `timer_vector` apos
/// `divisor` contagens e nao se rearma automaticamente.
pub fn timerOneShot(divisor: u32) void {
    // Desabilita o timer antes de reconfigurar.
    write32(ApicOffset.timer_config, 0x0001_0000); // mascarado, one-shot
    write32(ApicOffset.timer_icr, divisor);
}

pub fn timerStop() void {
    write32(ApicOffset.timer_config, 0x0001_0000); // Mascarado (bit 16 = 1)
}

pub fn setTimerDivide(divide_value: u32) void {
    write32(ApicOffset.timer_divide, divide_value & 0x0B); // Apenas os bits de divisao
}

/// Configura o timer local da APIC no modo periodico.
///
/// `divisor` divide a frequencia do barramento do timer. O timer dispara
/// o vetor `timer_vector` periodicamente e se rearma automaticamente.
pub fn timerPeriodic(divisor: u32) void {
    // Bit 17 = periodico, mascarado por enquanto (bit 16 = 0).
    write32(ApicOffset.timer_config, 0x0002_0000 | timer_vector);
    write32(ApicOffset.timer_icr, divisor);
}

/// The vector of the reschedule IPI.
///
/// One vector per CPU, delivered as a fixed IPI: the processor that receives it
/// re-evaluates its own queue instead of waiting for the next tick of a clock it
/// may not even have. The number is above the local timer (64), which is the
/// only other vector the kernel uses beyond the hardware range.
pub const reschedule_vector: u8 = 65;

/// Sends a reschedule IPI to one CPU (physical destination, fixed delivery).
///
/// The caller checks the destination (`smp.reschedule` does): an IPI to a
/// processor that is not in long mode yet lands in whatever that processor is
/// doing, and to its own APIC id it is a message to itself that the hardware
/// may refuse.
pub fn sendReschedule(apic_id: u32) void {
    sendIpi(apic_id, 0, reschedule_vector);
}

/// The vector of the TLB shootdown IPI.
///
/// The IPI carries a vector and nothing else, so the page travels through
/// memory (`tlb.Mailbox`) and this vector is only the announcement that a new
/// request is there. It sits above the reschedule (65) for the same reason: the
/// hardware range keeps the devices, and every vector the kernel invents lives
/// above it.
pub const shootdown_vector: u8 = 66;

/// Tells one CPU that the mailbox has a new translation to forget.
pub fn sendShootdown(apic_id: u32) void {
    sendIpi(apic_id, 0, shootdown_vector);
}

/// Envia uma IPI para uma CPU de destino (modo fisico).
///
/// `apic_id` e o ID de APIC local da CPU de destino. `delivery_mode` e o
/// tipo de comando (fixed, lowest_priority, init, startup etc.).
pub fn sendIpi(apic_id: u32, delivery_mode: u32, vector: u8) void {
    // Espera ate que a IPI anterior tenha sido entregue.
    while (read32(ApicOffset.icr_low) & @as(u32, @intFromEnum(IcrDeliveryStatus.pending)) != 0) {
        cpu.pause();
    }
    // ICR alto: ID de destino no byte mais significativo.
    write32(ApicOffset.icr_high, apic_id << 24);
    // ICR baixo: delivery mode + vector + edge trigger + physical destination.
    const command: u32 = delivery_mode |
        @as(u32, @intFromEnum(IcrLevel.assert)) |
        @as(u32, @intFromEnum(IcrTriggerMode.edge)) |
        @as(u32, @intFromEnum(IcrDestinationMode.physical)) |
        @as(u32, vector);
    write32(ApicOffset.icr_low, command);
}

/// Envia uma IPI INIT para todos exceto o emissor (modo broadcast fisico).
pub fn sendInitAllExcludingSelf() void {
    while (read32(ApicOffset.icr_low) & @as(u32, @intFromEnum(IcrDeliveryStatus.pending)) != 0) {
        cpu.pause();
    }
    write32(ApicOffset.icr_high, 0);
    const command: u32 = IcrDeliveryMode.init | IcrLevel.assert |
        IcrTriggerMode.edge | IcrDestinationMode.physical |
        IcrDestinationShorthand.all_excluding_self;
    write32(ApicOffset.icr_low, command);
}

/// Envia uma IPI de STARTUP (SIPI) para um AP.
///
/// `apic_id` e o ID de APIC local do AP. `vector` e o vetor de
/// inicializacao (o endereco do trampoline eh vector * 4096 bytes).
pub fn sendSipi(apic_id: u32, vector: u8) void {
    while (read32(ApicOffset.icr_low) & @as(u32, @intFromEnum(IcrDeliveryStatus.pending)) != 0) {
        cpu.pause();
    }
    write32(ApicOffset.icr_high, apic_id << 24);
    const command: u32 = @as(u32, @intFromEnum(IcrDeliveryMode.startup)) |
        @as(u32, @intFromEnum(IcrLevel.assert)) |
        @as(u32, @intFromEnum(IcrTriggerMode.edge)) |
        @as(u32, @intFromEnum(IcrDestinationMode.physical)) |
        @as(u32, vector);
    write32(ApicOffset.icr_low, command);
}

/// Envia uma IPI INIT para uma CPU de destino (modo fisico, nivel assert).
///
/// O INIT coloca o processador de aplicacao no estado de espera de SIPI. Ele
/// e a primeira mensagem da sequencia INIT-SIPI-SIPI do protocolo de boot
/// multiprocessador; sem ele o AP pode nao aceitar o vetor de inicializacao.
pub fn sendInit(apic_id: u32) void {
    while (read32(ApicOffset.icr_low) & @as(u32, @intFromEnum(IcrDeliveryStatus.pending)) != 0) {
        cpu.pause();
    }
    write32(ApicOffset.icr_high, apic_id << 24);
    const command: u32 = @as(u32, @intFromEnum(IcrDeliveryMode.init)) |
        @as(u32, @intFromEnum(IcrLevel.assert)) |
        @as(u32, @intFromEnum(IcrTriggerMode.edge)) |
        @as(u32, @intFromEnum(IcrDestinationMode.physical));
    write32(ApicOffset.icr_low, command);
}

/// Segunda mensagem SIPI: envia o SIPI duas vezes com um intervalo,
/// conforme requerido pela especificacao do protocolo de boot multiprocessador.
pub fn sendSipiTwice(apic_id: u32, vector: u8) void {
    sendSipi(apic_id, vector);
    // Delay curto entre as mensagens SIPI.
    var i: u32 = 0;
    while (i < 1000) {
        cpu.pause();
        i += 1;
    }
    sendSipi(apic_id, vector);
}

test "apicOffsetsAreAligned" {
    try std.testing.expectEqual(@as(u64, 0x020), ApicOffset.id);
    try std.testing.expectEqual(@as(u64, 0x300), ApicOffset.icr_low);
    try std.testing.expectEqual(@as(u64, 0x310), ApicOffset.icr_high);
}

test "timerVectorIsAfterHardwareInterrupts" {
    try std.testing.expectEqual(@as(u32, 64), timer_vector);
}

test "the base address validation rejects unusable values" {
    try std.testing.expect(isValidBase(default_base));
    try std.testing.expect(isValidBase(0xFEC0_0000));
    try std.testing.expect(!isValidBase(0));
    try std.testing.expect(!isValidBase(default_base + 4));
    try std.testing.expect(!isValidBase(identity_mapped_limit));
    try std.testing.expect(!isValidBase(identity_mapped_limit + page_size));
}

test "setBase stores a valid address and resetBase restores the default" {
    const previous = baseAddress();
    defer setBase(previous) catch {};

    try setBase(0xFEC0_0000);
    try std.testing.expectEqual(@as(u64, 0xFEC0_0000), baseAddress());

    resetBase();
    try std.testing.expectEqual(default_base, baseAddress());
    try std.testing.expectEqual(@as(u64, 0xFEE0_0000), default_base);
}

test "setBase refuses the invalid values with a specific error" {
    const previous = baseAddress();
    defer setBase(previous) catch {};

    try std.testing.expectError(error.NullAddress, setBase(0));
    try std.testing.expectError(error.Misaligned, setBase(default_base + 1));
    try std.testing.expectError(error.OutOfRange, setBase(identity_mapped_limit));
    // A recusa nao altera o endereco em uso.
    try std.testing.expectEqual(previous, baseAddress());
}
