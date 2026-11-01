//************************************************************************//
//  smp.zig                                                               //
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

//! Suporte a multiprocessamento simétrico (SMP): dados por CPU e numeração.
//!
//! Este incremento estabelece as fundações para execução em múltiplos
//! processadores lógicos. Cada CPU lógica tem:
//!
//!   * um número de CPU (0 para o BSP, 1..N para os APs);
//!   * um ID de APIC local;
//!   * um ponteiro para a tarefa que está executando;
//!   * um ponteiro para o escalonador da CPU.
//!
//! O kernel prepara as pilhas, **copia e preenche o trampoline abaixo de 1 MiB**
//! (`ap_trampoline.zig` + `prepareTrampoline`), envia INIT/SIPI por AP e recebe
//! cada um em `kynox_ap_entry`. Nesta etapa o AP instala o proprio segmento e
//! fica em espera com interrupcoes ligadas; ainda nao participa do
//! escalonamento. Filas per-CPU, migracao de tarefas, coordenacao por IPI e
//! integracao SMP do scheduler continuam pendentes.

const std = @import("std");
const spinlock = @import("spinlock.zig");
const apic = @import("apic.zig");
const kynox = @import("kynox_shared");
const x86_cpu = @import("cpu.zig");
const acpi = @import("acpi.zig");
const segment = @import("segment.zig");
const trampoline = @import("ap_trampoline.zig");

/// Número máximo de CPUs lógicas suportadas.
pub const max_cpus: u8 = 8;

/// Estado de uma CPU lógica.
pub const CpuState = enum {
    /// A CPU não foi detectada ou não está presente.
    absent,
    /// A CPU está online e executando tarefas.
    online,
    /// A CPU está sendo inicializada (AP em processo de boot).
    initializing,
    /// A CPU foi desligada.
    offline,
    /// A CPU falhou (falha de inicialização, erro de hardware).
    failed,
};

/// Dados privados de uma CPU lógica.
pub const Cpu = struct {
    /// Número da CPU (0 para o BSP, 1..N para os APs).
    id: u8 = 0,
    /// ID de APIC local da CPU.
    apic_id: u32 = 0,
    /// Estado atual da CPU.
    state: CpuState = .absent,
    /// Tarefa que está executando nesta CPU (null se nenhuma).
    current_task: ?*anyopaque = null,
    /// Espinlock que protege os dados desta CPU.
    lock: spinlock.Spinlock = .{},
};

/// Tabela de CPUs: um slot por número de CPU lógica.
var cpus: [max_cpus]Cpu = @splat(.{});

/// Número de CPUs online atualmente.
var online_cpu_count: u8 = 1;

/// Número de CPUs descritas pela MADT (incluindo o BSP).
var discovered_cpu_count: u8 = 1;

/// Índice do BSP na tabela.
var bsp_index: u8 = 0;

/// O trampolim dos APs foi copiado e preenchido abaixo de 1 MiB.
///
/// A flag começa falsa e `startAps` recusa enviar IPIs enquanto ela for falsa:
/// um AP iniciado numa pagina que nao contem o bloco executa o que estiver la.
/// `prepareTrampoline` e a unica coisa que a torna verdadeira, e ela so
/// completa quando a copia, os campos e a colocacao passaram.
var trampoline_ready: bool = false;

/// Endereço físico onde o trampolim foi publicado.
var trampoline_base: u64 = 0;

/// Os deslocamentos dos campos do trampolim, lidos dos símbolos do Assembly.
///
/// Ficam guardados porque `armTrampolineFor` precisa deles no laço de SIPI, e
/// porque a preparação valida o layout uma vez em vez de a cada AP.
var trampoline_layout: trampoline.Layout = .{};

/// Marca o trampolim como publicado, no endereco dado.
///
/// Nao deve ser chamada para "anunciar" uma copia que nao aconteceu: quem copia
/// e preenche os campos e `prepareTrampoline`, que valida a colocacao e o
/// layout antes de chamar esta funcao.
pub fn publishTrampoline(base: u64) void {
    trampoline_base = base;
    trampoline_ready = base != 0;
}

/// Copia e preenche o trampolim na pagina baixa que a SIPI nomeia.
///
/// A pagina tem de estar **abaixo de 1 MiB** — o vetor da SIPI tem oito bits, e
/// o processador comeca em modo real em `vetor * 4096` — e o kernel nao precisa
/// procura-la: `physical.minimum_address` reserva toda a memoria baixa, entao o
/// gerenciador de paginas fisicas nunca a entrega. O chamador ainda confere no
/// mapa de memoria que a pagina e RAM utilizavel; esta funcao confere a
/// colocacao e os campos.
///
/// Devolve o erro quando a copia nao aconteceu: um booleano aqui esconderia
/// **qual** pre-condicao falhou, e um AP iniciado sem trampolim executa o que
/// estiver naquela pagina.
pub fn prepareTrampoline(address: u64, cr3: u64, efer_bits: u32) ?trampoline.Error {
    const layout = trampoline.kernelLayout();
    trampoline.validatePlacement(address, layout.size) catch |err| return err;

    const destination = @as([*]u8, @ptrFromInt(address))[0..@intCast(trampoline.page_size)];
    const source = trampoline.imageAddress()[0..layout.size];

    trampoline.install(destination, source, layout, .{
        .block_base = address,
        .cr3 = cr3,
        .efer = efer_bits,
        .far32_target = address + trampoline.protectedModeOffset(),
        .entry = @intFromPtr(&kynox_ap_entry),
    }) catch |err| return err;

    trampoline_layout = layout;
    publishTrampoline(address);
    return null;
}

/// Preenche os campos que mudam por AP e libera aquele AP.
///
/// Chamada para **um** AP de cada vez, imediatamente antes do INIT/SIPI dele:
/// o bloco e um so e todos os APs o leem. A ordem dos campos esta no modulo do
/// trampolim (`ready` por ultimo), e e a razao de a funcao existir separada da
/// copia.
pub fn armTrampolineFor(cpu_index: u8, stack_top: u64) bool {
    if (!trampoline_ready) return false;
    if (cpu_index >= max_cpus) return false;

    const destination = @as([*]u8, @ptrFromInt(trampoline_base))[0..@intCast(trampoline.page_size)];
    trampoline.arm(destination, trampoline_layout, .{
        .stack_top = stack_top,
        .cpu_id = cpu_index,
    }) catch return false;
    return true;
}

/// Endereco do trampolim publicado, ou zero enquanto ele nao foi publicado.
pub fn trampolineAddress() u64 {
    return trampoline_base;
}

/// O trampolim esta pronto para iniciar APs?
pub fn trampolinePublished() bool {
    return trampoline_ready;
}

/// Número de CPUs descobertas na MADT, incluindo o BSP.
pub fn discoveredCpuCount() u8 {
    return discovered_cpu_count;
}

/// Número de processadores de aplicação descobertos (exclui o BSP).
pub fn apCount() u8 {
    if (discovered_cpu_count <= 1) return 0;
    return discovered_cpu_count - 1;
}

/// Índice do BSP na tabela.
pub fn bspCpuIndex() u8 {
    return bsp_index;
}

/// Maps an APIC id to its index in the CPU table.
pub fn cpuIndexForApicId(apic_id: u32) ?u8 {
    var index: u8 = 0;
    while (index < discovered_cpu_count) : (index += 1) {
        if (cpus[index].apic_id == apic_id) return index;
    }
    return null;
}

/// Returns the logical number of the current CPU.
///
/// The number comes from the local APIC id, translated through the table
/// built from the MADT. Before the APIC is mapped, and on a processor that
/// the MADT did not name, the BSP index is returned: the kernel must keep
/// running even when the firmware description is incomplete.
pub fn cpuId() u8 {
    if (!apic.isMapped()) return bsp_index;
    return cpuIndexForApicId(apic.readApicId()) orelse bsp_index;
}

/// Retorna o ponteiro para a estrutura da CPU atual.
pub fn currentCpu() *Cpu {
    return &cpus[cpuId()];
}

/// Retorna o número de CPUs online.
pub fn cpuCount() u8 {
    return online_cpu_count;
}

/// Registra uma CPU na tabela. Chamado durante a inicialização do BSP
/// e, futuramente, durante o boot de cada AP.
pub fn registerCpu(id: u8, apic_id: u32) ?*Cpu {
    if (id >= max_cpus) return null;
    const cpu = &cpus[id];
    // K3.12.2 fix: prevent double-increment on cpu 0 or re-registration.
    if (cpu.state == .online or cpu.state == .failed) return cpu;
    cpu.* = .{
        .id = id,
        .apic_id = apic_id,
        .state = .online,
        .current_task = null,
    };
    if (id == 0 or online_cpu_count < max_cpus) {
        online_cpu_count = @min(online_cpu_count + 1, max_cpus);
    }
    return cpu;
}

/// Marca uma CPU como offline.
pub fn offlineCpu(id: u8) void {
    if (id >= max_cpus) return;
    cpus[id].state = .offline;
    online_cpu_count = @max(online_cpu_count - 1, 1);
}

test "cpuId returns zero on single-CPU system" {
    try std.testing.expectEqual(cpuId(), 0);
}

test "registerCpu adds a CPU to the table" {
    online_cpu_count = 1;
    const c = registerCpu(0, 0) orelse return;
    try std.testing.expectEqual(c.id, 0);
    try std.testing.expectEqual(c.apic_id, 0);
    try std.testing.expectEqual(c.state, .online);
}

test "registerCpu rejects IDs above max_cpus" {
    try std.testing.expectEqual(registerCpu(max_cpus, 0), null);
}

test "offlineCpu reduces the online count but keeps at least one" {
    online_cpu_count = 4;
    offlineCpu(3);
    try std.testing.expectEqual(cpuCount(), 3);
    offlineCpu(2);
    offlineCpu(1);
    try std.testing.expectEqual(cpuCount(), 1);
}

/// Pilhas de kernel dos APs (uma por CPU, excluindo o BSP que ja tem sua
/// pilha em `kernel/main.zig`).
///
/// Cada pilha tem 16 KiB e esta alinhada a 16 bytes. O topo da pilha
/// (`_end`) e usado pelo trampoline como ponteiro inicial de pilha.
var ap_stacks: [max_cpus][16 * 1024]u8 align(16) = undefined;

/// Endereco do topo da pilha de cada CPU, indexado pelo **indice da tabela de
/// CPUs** (o mesmo numero que `cpuId()` devolve e que o trampoline passa em
/// RDI). O slot do BSP fica sem uso: o BSP tem a pilha de boot.
///
/// O indice era `cpu_id - 1`, que so vale quando o BSP e a entrada zero da
/// tabela — e a tabela vem da MADT, onde o BSP pode ser qualquer entrada. Com
/// o BSP na entrada 1, o AP que recebesse `cpu_id = 1` escreveria na pilha
/// errada e registraria a CPU errada.
pub export var ap_stack_top: [max_cpus]u64 = @splat(0);

/// Ponto de entrada de um AP, chamado pelo trampoline em modo longo.
///
/// `cpu_id` e o numero logico da CPU (passado pelo trampoline em RDI).
/// A funcao registra a CPU na tabela, configura sua pilha e entra no
/// escalonador. Nunca retorna.
pub export fn kynox_ap_entry(cpu_id: u8) void {
    // `cpu_id` e o indice da tabela de CPUs, nao `indice + 1`: a tabela vem da
    // MADT e o BSP pode ocupar qualquer entrada. Tudo o que e por CPU usa o
    // mesmo numero, para nao haver duas numeracoes.
    if (cpu_id >= max_cpus) {
        while (true) x86_cpu.waitForInterrupt();
    }
    const cpu_index: usize = cpu_id;

    // Estabelece a pilha do kernel desta CPU.
    const stack = &ap_stacks[cpu_index];
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    const aligned_top = stack_top & ~@as(u64, 0xF);

    // Registra a CPU na tabela SMP.
    const apic_id = apic.readApicId();
    const cpu = registerCpu(cpu_id, apic_id) orelse {
        // Nao ha espaco na tabela: entra em loop de espera.
        while (true) {}
    };
    cpu.current_task = null;

    // Marca a pilha como disponivel para o escalonador.
    ap_stack_top[cpu_index] = aligned_top;

    // A CPU recebe a propria tabela de segmentos e o proprio segmento de
    // estado da tarefa: um `rsp0` global seria a pilha de kernel da CPU que o
    // escreveu por ultimo. `ist1` aponta para a pilha de double fault desta
    // CPU, que o gate do vetor 8 ja usa.
    segment.installForCpu(cpu_id, aligned_top);

    // Sinaliza que esta CPU esta online.
    cpu.state = .online;

    // Entra no loop da CPU: aguarda por trabalho do escalonador.
    // O escalonador ainda e monoprocessador; quando o suporte a multiprocessador
    // estiver completo, esta funcao escolhera tarefas da fila desta CPU.
    //
    // `sti; hlt` e nao `hlt`: um AP que chega aqui com interrupcoes desligadas
    // e um `hlt` fica parado para sempre, sem nem receber a IPI que o
    // acordaria. Assim ele dorme e volta a cada interrupcao.
    while (true) {
        x86_cpu.waitForInterrupt();
    }
}

/// Inicializa o suporte a AP no BSP.
///
/// Deve ser chamado pelo kernel apos a inicializacao do BSP. Configura
/// os enderecos de pilha dos APs e prepara o trampoline para copia.
pub fn initAps() void {
    var i: usize = 0;
    while (i < max_cpus) : (i += 1) {
        const stack = &ap_stacks[i];
        const stack_top = @intFromPtr(stack.ptr) + stack.len;
        ap_stack_top[i] = stack_top & ~@as(u64, 0xF);
    }
}

/// Configures the CPU table from the processors of the MADT.
///
/// The kernel no longer assumes that APIC ids are sequential: the table is
/// built from the entries the firmware published, in the order they appear,
/// skipping disabled processors and duplicates. The BSP is the entry whose
/// APIC id matches `bsp_apic_id`; the BSP is `online` from the start, the APs
/// stay `initializing` until `kynox_ap_entry` runs on them.
///
/// When the MADT names no processor at all (or only disabled ones) the table
/// keeps a single entry for the BSP. A boot must not depend on a table being
/// complete.
///
/// Returns the number of entries in the table, including the BSP.
pub fn configureFromMadt(processors: []const acpi.Processor, bsp_apic_id: u32) u8 {
    cpus = @splat(.{});
    discovered_cpu_count = 0;
    online_cpu_count = 1;
    bsp_index = 0;

    for (processors) |processor| {
        if (!processor.enabled) continue;
        if (discovered_cpu_count >= max_cpus) break;
        if (cpuIndexForApicId(processor.apic_id) != null) continue;

        const index = discovered_cpu_count;
        cpus[index] = .{
            .id = index,
            .apic_id = processor.apic_id,
            .state = if (processor.apic_id == bsp_apic_id) .online else .initializing,
            .current_task = null,
        };
        discovered_cpu_count += 1;
    }

    if (discovered_cpu_count == 0) {
        cpus[0] = .{ .id = 0, .apic_id = bsp_apic_id, .state = .online };
        discovered_cpu_count = 1;
    }

    bsp_index = cpuIndexForApicId(bsp_apic_id) orelse 0;
    // The BSP is always online, even if the firmware did not describe it.
    cpus[bsp_index].state = .online;
    return discovered_cpu_count;
}

/// Returns the APIC id of a CPU index, or null when the index is not used.
pub fn apicIdFor(cpu_index: u8) ?u32 {
    if (cpu_index >= discovered_cpu_count) return null;
    return cpus[cpu_index].apic_id;
}

/// True when the CPU at `cpu_index` reached `.online` before the deadline.
fn waitForOnline(cpu_index: u8, spins: u64) bool {
    var remaining = spins;
    while (remaining > 0) : (remaining -= 1) {
        if (cpus[cpu_index].state == .online) return true;
        x86_cpu.pause();
    }
    return cpus[cpu_index].state == .online;
}

/// Starts the application processors discovered in the MADT.
///
/// The function is deliberately conservative. It checks two preconditions
/// before sending any IPI:
///
///   * at least one AP was discovered — a single-CPU machine sends nothing;
///   * the trampoline has been published below 1 MiB — copied and filled by
///     `prepareTrampoline`, and an AP started without it executes whatever is
///     at the SIPI vector.
///
/// When a precondition fails, the reason is logged and no IPI is sent. When
/// both hold, each discovered AP receives INIT-SIPI-SIPI and the BSP waits for
/// its `online` flag with a bounded number of pauses; an AP that does not
/// answer is reported and left `initializing`, never assumed online.
pub fn startAps() void {
    const ap_total = apCount();
    if (ap_total == 0) {
        kynox.serial.printLine("[KNK] smp: no application processor beyond the BSP; nothing to start", .{});
        return;
    }

    if (!trampoline_ready) {
        kynox.serial.printLine(
            "[KNK] smp: {d} APs discovered, startup blocked: the trampoline is not published below 1 MiB",
            .{ap_total},
        );
        return;
    }

    kynox.serial.printLine("[KNK] smp: starting {d} APs from the MADT (trampoline at 0x{x})", .{
        ap_total, trampoline_base,
    });

    var index: u8 = 0;
    while (index < discovered_cpu_count) : (index += 1) {
        if (index == bsp_index) continue;
        const apic_id = cpus[index].apic_id;

        // O bloco e um so, compartilhado por todos os APs: os campos deste AP
        // (pilha, numero da CPU) sao escritos imediatamente antes da SIPI dele,
        // e `ready` e a ultima escrita. Sem isso o AP leria a pilha do AP
        // anterior.
        if (!armTrampolineFor(index, ap_stack_top[index])) {
            kynox.serial.printLine("[KNK] smp: AP cpu={d} not started: the trampoline refused the fields", .{index});
            continue;
        }

        // INIT, then two STARTUP IPIs, as the processor specification
        // requires. The vector is the page of the trampoline.
        apic.sendInit(apic_id);
        apic.sendSipiTwice(apic_id, @intCast(trampoline_base >> 12));

        if (waitForOnline(index, 50_000_000)) {
            online_cpu_count = @min(online_cpu_count + 1, max_cpus);
            kynox.serial.printLine("[KNK] smp: AP cpu={d} apic id={d} online", .{ index, apic_id });
        } else {
            kynox.serial.printLine("[KNK] smp: AP cpu={d} apic id={d} did not answer before the deadline", .{
                index, apic_id,
            });
        }
    }
}

/// O ponteiro para o bloco do trampoline como ele esta ligado no kernel.
///
/// O bloco e copiado dessa imagem para a pagina baixa por `prepareTrampoline`;
/// nada executa esta copia no lugar em que ela foi ligada.
pub fn apTrampolineInfo() [*]const u8 {
    return trampoline.imageAddress();
}

test "the trampoline is not published until the block is copied into the page" {
    defer publishTrampoline(0);

    // The kernel starts with no trampoline, and `startAps` refuses to send an
    // IPI in that state: an AP started on a page without the block executes
    // whatever is there.
    publishTrampoline(0);
    try std.testing.expect(!trampolinePublished());
    try std.testing.expectEqual(@as(u64, 0), trampolineAddress());
    try std.testing.expect(!armTrampolineFor(1, 0x10_0000));
}

test "publishing an address does not arm an AP when the fields were never laid out" {
    // `publishTrampoline` only announces an address. Arming an AP needs the
    // layout of the block, which only `prepareTrampoline` fills after the copy:
    // an announcement on its own must not become a running processor.
    publishTrampoline(trampoline.base_address);
    defer publishTrampoline(0);

    try std.testing.expect(trampolinePublished());
    try std.testing.expect(!armTrampolineFor(1, 0x10_0000));
    // A CPU number that the table does not have is refused as well.
    try std.testing.expect(!armTrampolineFor(max_cpus, 0x10_0000));
}

test "the stack of an AP is indexed by the number of the CPU in the table" {
    // The table comes from the MADT and the BSP can be any entry, so the stack
    // of an AP cannot be indexed by `cpu - 1`. `initAps` fills one entry per
    // logical CPU, and the entry of a CPU is the one its trampoline receives.
    initAps();

    var index: usize = 0;
    while (index < max_cpus) : (index += 1) {
        try std.testing.expectEqual(@as(u64, 0) & 0xF, ap_stack_top[index] & 0xF);
        try std.testing.expect(ap_stack_top[index] != 0);
        try std.testing.expectEqual(
            @intFromPtr(&ap_stacks[index]) + ap_stacks[index].len,
            ap_stack_top[index],
        );
    }
}

test "the CPU table follows the MADT order and skips disabled processors" {
    const processors = [_]acpi.Processor{
        .{ .apic_id = 4, .enabled = true },
        .{ .apic_id = 9, .enabled = false },
        .{ .apic_id = 0, .enabled = true },
        .{ .apic_id = 4, .enabled = true },
    };

    const known = configureFromMadt(&processors, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    try std.testing.expectEqual(@as(u8, 2), known);
    try std.testing.expectEqual(@as(u32, 4), apicIdFor(0).?);
    try std.testing.expectEqual(@as(u32, 0), apicIdFor(1).?);
    try std.testing.expect(apicIdFor(2) == null);
    try std.testing.expectEqual(@as(u8, 1), bspCpuIndex());
    try std.testing.expectEqual(@as(u8, 1), apCount());
    try std.testing.expectEqual(@as(u8, 1), cpuId());
}

test "a table without the BSP keeps the BSP online at index zero" {
    const processors = [_]acpi.Processor{
        .{ .apic_id = 12, .enabled = true },
        .{ .apic_id = 13, .enabled = true },
    };

    const known = configureFromMadt(&processors, 7);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    try std.testing.expectEqual(@as(u8, 2), known);
    try std.testing.expectEqual(@as(u8, 0), bspCpuIndex());
    try std.testing.expectEqual(CpuState.online, cpus[0].state);
    try std.testing.expectEqual(CpuState.initializing, cpus[1].state);
}

test "an empty MADT leaves a single online BSP" {
    const known = configureFromMadt(&[_]acpi.Processor{}, 3);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    try std.testing.expectEqual(@as(u8, 1), known);
    try std.testing.expectEqual(@as(u8, 0), apCount());
    try std.testing.expectEqual(@as(u32, 3), apicIdFor(0).?);
    try std.testing.expectEqual(CpuState.online, cpus[0].state);
}

test "the table never grows beyond the maximum number of CPUs" {
    var processors: [max_cpus + 4]acpi.Processor = @splat(.{ .apic_id = 0, .enabled = true });
    for (&processors, 0..) |*processor, index| {
        processor.apic_id = @intCast(index + 1);
    }

    const known = configureFromMadt(&processors, 1);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    try std.testing.expectEqual(max_cpus, known);
    try std.testing.expectEqual(@as(u8, max_cpus - 1), apCount());
}
