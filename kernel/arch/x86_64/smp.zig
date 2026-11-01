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
const tlb = @import("tlb.zig");

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

/// O resultado de um pedido de reschedule.
///
/// Nao e um booleano porque cada recusa e um motivo diferente, e o boot diz
/// qual: a CPU errada, uma CPU que nao esta online, ou um APIC local que nao
/// foi mapeado (o que, no host, e o caso normal).
pub const RescheduleOutcome = enum {
    /// A IPI foi entregue ao controlador.
    sent,
    /// O destino e a CPU que fez o pedido: nao ha o que acordar.
    same_cpu,
    /// O numero nao existe na tabela de CPUs.
    unknown_cpu,
    /// A CPU existe e nao esta online: ela nao pode receber a IPI.
    not_online,
    /// O APIC local nao esta mapeado, entao o controlador nao pode ser escrito.
    no_apic,
};

var reschedule_requests: u64 = 0;

/// Acorda uma CPU para ela reavaliar a propria fila.
///
/// A fila de uma CPU pertence a ela (`scheduler.Task.cpu`), e uma CPU sem relogio
/// proprio dorme em `sti; hlt`. Quando uma tarefa dessa CPU fica pronta por causa
/// de outra CPU, alguem tem de acordar a dona: e esta funcao.
///
/// Os tres destinos que nao podem receber a IPI sao recusados **antes** de
/// escrever no controlador: a CPU que pergunta por si mesma (a IPI para o
/// proprio APIC id pode ser recusada pelo hardware, e o pedido seria uma
/// interrupcao para nada), um numero que a tabela nao tem, e uma CPU que existe
/// mas ainda nao esta `online` — mandar uma IPI fixa para um processador em modo
/// real ou desligado e entregar um vetor a quem nao tem IDT.
pub fn reschedule(cpu_index: u8) RescheduleOutcome {
    if (cpu_index >= max_cpus or cpu_index >= discovered_cpu_count) return .unknown_cpu;
    if (cpu_index == cpuId()) return .same_cpu;
    if (cpus[cpu_index].state != .online) return .not_online;
    if (!apic.isMapped()) return .no_apic;

    apic.sendReschedule(cpus[cpu_index].apic_id);
    reschedule_requests += 1;
    return .sent;
}

/// The first application processor that is online, or null.
///
/// It is the destination of the first migration: an AP with an empty queue and
/// no work is a processor that halts, and the tasks of the boot are created by
/// the BSP.
pub fn firstOnlineAp() ?u8 {
    var index: u8 = 0;
    while (index < discovered_cpu_count) : (index += 1) {
        if (index == bsp_index) continue;
        if (cpus[index].state == .online) return index;
    }
    return null;
}

/// Quantas IPIs de reschedule foram realmente entregues.
pub fn rescheduleRequests() u64 {
    return reschedule_requests;
}

/// O resultado de um TLB shootdown.
///
/// Como no reschedule, nao e um booleano: "nao havia ninguem a quem pedir" e
/// "havia, e eu nao podia falar com eles" sao fatos diferentes, e o segundo e o
/// caso normal de um host sem controlador.
pub const ShootdownOutcome = enum {
    /// Todos os processadores avisados responderam: a traducao sumiu de todos.
    complete,
    /// Nao ha outro processador online: a invalidacao local e a historia toda.
    no_targets,
    /// Ha outro processador online e o APIC local nao esta mapeado, entao
    /// ninguem pode ser avisado.
    no_apic,
    /// O pedido foi publicado e as IPIs sairam, mas alguem nao respondeu a
    /// tempo. A pagina pode continuar traduzida nessa CPU.
    timeout,
};

/// Quantas voltas de `pause` o remetente espera pelas respostas.
///
/// O orcamento e grande de proposito: uma resposta custa uma invalidacao e um
/// reconhecimento, e desistir cedo demais transformaria um shootdown lento em
/// uma garantia perdida. O numero existe para que a maquina nao trave para
/// sempre quando um processador esta morto ou preso.
const shootdown_spin_budget: u32 = 4 * 1024 * 1024;

/// A caixa de correio do shootdown: um pedido no ar por vez.
var shootdown_mailbox: tlb.Mailbox = .{};

/// O lock do remetente. Os receptores nunca o tocam: quem espera a resposta nao
/// pode ser o mesmo que a responde.
var shootdown_lock: spinlock.Spinlock = .{};

var shootdowns: u64 = 0;
var shootdown_timeouts: u64 = 0;

/// Pede a todos os outros processadores que esqueçam uma traducao.
///
/// Uma entrada obsoleta no TLB de outro processador e memoria que continua
/// acessivel depois de a tabela dizer que nao esta: a pagina volta para o
/// alocador, outro dono a recebe, e a CPU que guardou a traducao velha escreve
/// na pagina do novo dono. A invalidacao local (`invlpg`) cobre so este
/// processador, e e por isso que existe esta funcao.
///
/// O pedido e publicado em `tlb.Mailbox` — a IPI carrega um vetor e nao um
/// endereco — e este processador espera as respostas por um tempo limitado. Se
/// alguma faltar, o pedido e abandonado e o resultado diz `timeout`: uma
/// garantia perdida e reportada, nunca escondida atras de um sucesso.
pub fn shootdown(scope: tlb.Scope, address: u64) ShootdownOutcome {
    const self_index = cpuId();

    var targets: u32 = 0;
    var index: u8 = 0;
    while (index < discovered_cpu_count) : (index += 1) {
        if (index == self_index) continue;
        if (cpus[index].state != .online) continue;
        targets += 1;
    }

    // Uma maquina com um processador nao tem traducao remota para esquecer, e
    // esse e o caso normal da suite de host.
    if (targets == 0) return .no_targets;
    if (!apic.isMapped()) return .no_apic;

    shootdown_lock.lock();
    defer shootdown_lock.unlock();

    _ = shootdown_mailbox.begin(scope, address, targets);
    shootdowns += 1;

    index = 0;
    while (index < discovered_cpu_count) : (index += 1) {
        if (index == self_index) continue;
        if (cpus[index].state != .online) continue;
        apic.sendShootdown(cpus[index].apic_id);
    }

    var spins: u32 = 0;
    while (!shootdown_mailbox.isComplete()) {
        if (spins == shootdown_spin_budget) {
            shootdown_mailbox.abandon();
            shootdown_timeouts += 1;
            return .timeout;
        }
        x86_cpu.pause();
        spins += 1;
    }

    return .complete;
}

/// O que esta CPU faz quando recebe o aviso de um shootdown.
///
/// Roda no handler da interrupcao, no processador que tem a traducao velha: ele
/// invalida e responde. Um aviso reentregue — ou um pedido que esta CPU ja
/// serviu — nao tem o que fazer, e `latch` e quem sabe disso.
pub fn handleShootdown() tlb.Ack {
    const index = cpuId();
    const request = shootdown_mailbox.latch(index) orelse return .idle;

    switch (request.scope) {
        .page => x86_cpu.invlpg(request.address),
        .all => x86_cpu.flushTlb(),
    }

    return shootdown_mailbox.acknowledge(index, request);
}

/// O gancho que as tabelas de pagina instalam para a pagina que sai.
///
/// `paging.zig` nao importa este modulo: um import circular entre o mapeamento e
/// o SMP amarraria as duas camadas, e os testes das tabelas rodam sem
/// controlador. O boot instala `paging.installRemoteFlush(&flushRemotePage)`.
pub fn flushRemotePage(virtual: u64) void {
    _ = shootdown(.page, virtual);
}

/// Quantos pedidos de shootdown foram publicados.
pub fn shootdownsSent() u64 {
    return shootdowns;
}

/// Quantos pedidos foram abandonados por falta de resposta.
pub fn shootdownTimeouts() u64 {
    return shootdown_timeouts;
}

/// Quantos avisos os processadores desta maquina ja serviram.
pub fn shootdownsServed() u64 {
    return shootdown_mailbox.served;
}

/// Quantas respostas ainda faltam no pedido no ar.
pub fn shootdownOutstanding() u32 {
    return shootdown_mailbox.outstanding();
}

/// Publica um pedido sem enviar IPI nenhuma.
///
/// Existe para que o handler possa ser exercitado onde nao ha controlador: sem
/// ele, o caminho "recebe o aviso, invalida e responde" so rodaria em hardware,
/// e uma maquina que nunca recebeu uma IPI nao prova nada sobre o codigo que a
/// atende.
pub fn publishShootdownForTest(scope: tlb.Scope, address: u64, targets: u32) u64 {
    return shootdown_mailbox.begin(scope, address, targets).generation;
}

/// O que o kernel faz quando uma CPU chega em `kynox_ap_entry`.
///
/// Esta tabela existe para o `smp.zig` nao importar o escalonador: o
/// escalonador ja importa `smp` (para `cpuId` e `max_cpus`), e um import
/// circular entre os dois modulos amarraria a arquitetura ao escalonador. O
/// kernel instala a funcao no boot, e o AP a chama depois de instalar o proprio
/// segmento.
pub const CpuEntryHook = *const fn (cpu_index: u8, kernel_stack: []u8) void;

var cpu_entry_hook: ?CpuEntryHook = null;

/// Instala a funcao que poe uma CPU no escalonador.
///
/// Uma funcao nula e o estado de quem nao quer APs no escalonador: o AP instala
/// o segmento, marca-se online e espera.
pub fn installCpuEntryHook(hook: ?CpuEntryHook) void {
    cpu_entry_hook = hook;
}

/// A pilha de kernel de uma CPU logica, ou nula quando o numero nao existe.
pub fn stackOf(cpu_index: u8) ?[]u8 {
    if (cpu_index >= max_cpus) return null;
    return ap_stacks[cpu_index][0..];
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

    // A CPU entra no escalonador com uma tarefa propria, se o kernel instalou a
    // funcao. Sem ela, `current` desta CPU fica nulo, `prepareNext` retorna
    // antes de olhar a fila, e o AP espera para sempre com trabalho pronto ao
    // lado.
    if (cpu_entry_hook) |hook| hook(cpu_id, stack[0..]);

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
            // The counter is not incremented here: the AP incremented it when it
            // registered itself (`registerCpu`), and a second increment would
            // report one more processor than the machine has.
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

test "the first online AP is the one that is not the BSP" {
    const processors = [_]acpi.Processor{
        .{ .apic_id = 0, .enabled = true },
        .{ .apic_id = 7, .enabled = true },
        .{ .apic_id = 9, .enabled = true },
    };
    _ = configureFromMadt(&processors, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    // No AP has registered: there is nobody to migrate to.
    try std.testing.expectEqual(@as(?u8, null), firstOnlineAp());

    _ = registerCpu(2, 9);
    try std.testing.expectEqual(@as(u8, 2), firstOnlineAp().?);

    _ = registerCpu(1, 7);
    try std.testing.expectEqual(@as(u8, 1), firstOnlineAp().?);
}

test "an AP that registers itself is counted once" {
    // `configureFromMadt` leaves the APs `initializing`, and the counter of
    // online processors starts at one (the BSP). The AP increments it when it
    // registers, and nothing else may: a second increment reports one more
    // processor than the machine has.
    const processors = [_]acpi.Processor{
        .{ .apic_id = 0, .enabled = true },
        .{ .apic_id = 7, .enabled = true },
    };
    _ = configureFromMadt(&processors, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    try std.testing.expectEqual(@as(u8, 1), cpuCount());
    try std.testing.expectEqual(CpuState.initializing, cpus[1].state);

    _ = registerCpu(1, 7);
    try std.testing.expectEqual(@as(u8, 2), cpuCount());

    // A second registration of the same CPU changes nothing.
    _ = registerCpu(1, 7);
    try std.testing.expectEqual(@as(u8, 2), cpuCount());
}

test "a reschedule asks for the CPU that can receive it, and refuses the others" {
    const processors = [_]acpi.Processor{
        .{ .apic_id = 0, .enabled = true },
        .{ .apic_id = 7, .enabled = true },
    };
    _ = configureFromMadt(&processors, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    const before = rescheduleRequests();

    // The CPU that asks is not woken by an IPI to itself.
    try std.testing.expectEqual(RescheduleOutcome.same_cpu, reschedule(0));
    // A number that the table does not have.
    try std.testing.expectEqual(RescheduleOutcome.unknown_cpu, reschedule(2));
    try std.testing.expectEqual(RescheduleOutcome.unknown_cpu, reschedule(max_cpus));
    // The AP exists and has not registered: an IPI to a processor that is not in
    // long mode delivers a vector to a processor with no table of vectors.
    try std.testing.expectEqual(RescheduleOutcome.not_online, reschedule(1));

    // Online, but the local APIC is not mapped on this host: the controller
    // cannot be written, and the request is refused instead of faulting.
    _ = registerCpu(1, 7);
    try std.testing.expectEqual(RescheduleOutcome.no_apic, reschedule(1));

    // Nothing was delivered, so the counter that reports delivery did not move.
    try std.testing.expectEqual(before, rescheduleRequests());
}

test "a machine with one processor has no remote translation to forget" {
    _ = configureFromMadt(&[_]acpi.Processor{.{ .apic_id = 0, .enabled = true }}, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    const before_sent = shootdownsSent();
    const before_served = shootdownsServed();
    const before_timeouts = shootdownTimeouts();

    try std.testing.expectEqual(
        ShootdownOutcome.no_targets,
        shootdown(.page, 0x4000_0000),
    );

    // Nada foi publicado: nao ha pedido pendente, nao ha resposta a esperar, e
    // a invalidacao local que `invlpg` ja fez e a historia toda.
    try std.testing.expectEqual(before_sent, shootdownsSent());
    try std.testing.expectEqual(before_served, shootdownsServed());
    try std.testing.expectEqual(before_timeouts, shootdownTimeouts());
    try std.testing.expectEqual(@as(u32, 0), shootdownOutstanding());
}

test "a shootdown refuses to pretend when the controller is not mapped" {
    const processors = [_]acpi.Processor{
        .{ .apic_id = 0, .enabled = true },
        .{ .apic_id = 7, .enabled = true },
    };
    _ = configureFromMadt(&processors, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);
    _ = registerCpu(1, 7);

    const before = shootdownsSent();
    try std.testing.expectEqual(ShootdownOutcome.no_apic, shootdown(.all, 0));

    // A outra CPU esta online e ninguem pode avisa-la: um `.complete` aqui
    // seria a mentira mais cara do kernel, porque a traducao velha continua la.
    try std.testing.expectEqual(before, shootdownsSent());
    try std.testing.expectEqual(@as(u32, 0), shootdownOutstanding());
}

test "a spurious announcement invalidates nothing and counts nothing" {
    _ = configureFromMadt(&[_]acpi.Processor{.{ .apic_id = 0, .enabled = true }}, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    const before = shootdownsServed();
    try std.testing.expectEqual(tlb.Ack.idle, handleShootdown());
    try std.testing.expectEqual(before, shootdownsServed());
    try std.testing.expectEqual(@as(u32, 0), shootdownOutstanding());
}

test "the handler invalidates the page and acknowledges the request once" {
    _ = configureFromMadt(&[_]acpi.Processor{.{ .apic_id = 0, .enabled = true }}, 0);
    defer _ = configureFromMadt(&[_]acpi.Processor{}, 0);

    const served_before = shootdownsServed();
    const generation = publishShootdownForTest(.page, 0x2000, 1);
    try std.testing.expect(generation > 0);
    try std.testing.expectEqual(@as(u32, 1), shootdownOutstanding());

    // The handler runs with `invlpg` as a no-op on the host: what the test
    // observes is the protocol — one acknowledgement per request, and not one
    // more for a repeated announcement.
    try std.testing.expectEqual(tlb.Ack.accepted, handleShootdown());
    try std.testing.expectEqual(@as(u32, 0), shootdownOutstanding());
    try std.testing.expectEqual(served_before + 1, shootdownsServed());

    try std.testing.expectEqual(tlb.Ack.idle, handleShootdown());
    try std.testing.expectEqual(@as(u32, 0), shootdownOutstanding());
    try std.testing.expectEqual(served_before + 1, shootdownsServed());
}

test "the stack of a CPU is handed out for the numbers the table has" {
    // The entry of an AP gives its stack to the scheduler, which needs a slice
    // and not a pointer: the number it receives is the index of the CPU table,
    // and a number above the limit has no stack at all.
    const first = stackOf(0).?;
    const second = stackOf(1).?;

    try std.testing.expectEqual(@as(usize, 16 * 1024), first.len);
    try std.testing.expectEqual(@as(usize, 16 * 1024), second.len);
    try std.testing.expect(first.ptr != second.ptr);
    try std.testing.expectEqual(@as(?[]u8, null), stackOf(max_cpus));
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
