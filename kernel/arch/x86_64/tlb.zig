//************************************************************************//
//  tlb.zig                                                               //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                   //
//             https://github.com/CeoMatheusDev/Kynox                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 Kynox - All Rights Reserved.                        //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! A caixa de correio de um TLB shootdown.
//!
//! Uma IPI carrega um vetor e nada mais: nao ha espaco para o endereco que a
//! outra CPU tem de esquecer. O pedido viaja entao por memoria, e a IPI e so o
//! aviso de que ha um pedido novo — o mesmo desenho que os nucleos de producao
//! usam, e o motivo de o endereco e uma geracao morarem juntos.
//!
//! A geracao resolve o problema que aparece quando duas coisas dao errado ao
//! mesmo tempo: uma CPU pode receber o mesmo aviso duas vezes (a IPI e
//! reentregue, ou o receptor a serviu e o remetente desistiu depois), e um
//! reconhecimento atrasado nao pode consumir o pedido seguinte. Cada pedido
//! tem um numero que so cresce, e cada CPU guarda o ultimo que serviu.
//!
//! O remetente e unico — ele segura o lock do modulo enquanto o pedido esta no ar
//! — e os receptores nunca tocam nesse lock: eles so leem a geracao, invalidam a
//! traducao e descontam o pendente com um compare-and-swap. Um receptor que
//! esperasse pelo lock do remetente travaria a maquina, porque o remetente esta
//! esperando exatamente a resposta dele.

const std = @import("std");

/// Quantas CPUs logicas um pedido pode endereçar de uma vez.
pub const max_targets: usize = 8;

/// O que os processadores que recebem o aviso tem de esquecer.
pub const Scope = enum {
    /// Uma pagina: o processador executa `invlpg` com o endereco.
    page,
    /// Tudo: o processador recarrega o registrador da base das tabelas.
    all,
};

/// Um pedido, como o processador que o recebe o ve.
pub const Request = struct {
    /// O que esquecer.
    scope: Scope = .page,
    /// A pagina, quando o escopo e `page`. Zero nao e um endereco valido aqui:
    /// o escopo `all` e o que pede o esquecimento completo.
    address: u64 = 0,
    /// O numero do pedido. Comeca em um: zero e "nunca houve pedido".
    generation: u64 = 0,
};

/// O que aconteceu com um reconhecimento.
pub const Ack = enum {
    /// O pedido era novo para esta CPU: ela invalidou e descontou.
    accepted,
    /// Esta CPU ja tinha servido este mesmo pedido.
    duplicate,
    /// Nao havia pedido nenhum no ar.
    idle,
    /// O pedido que esta CPU serviu foi substituido antes do reconhecimento.
    stale,
};

/// A caixa de correio: um pedido no ar por vez, com a contagem das respostas.
pub const Mailbox = struct {
    /// O pedido publicado. Os campos sao escritos pelo remetente antes de a
    /// geracao ser publicada com release, entao quem le a geracao com acquire
    /// ve o escopo e o endereco que combinam com ela.
    scope: Scope = .page,
    address: u64 = 0,
    generation: std.atomic.Value(u64) = .init(0),
    /// Quantas CPUs ainda devem uma resposta.
    pending: std.atomic.Value(u32) = .init(0),
    /// Quantas respostas foram aceitas desde o boot.
    served: u64 = 0,
    /// Quantos pedidos foram publicados.
    started: u64 = 0,
    /// Quantos pedidos foram abandonados por falta de resposta.
    timeouts: u64 = 0,
    /// A ultima geracao que cada CPU serviu. Cada CPU escreve a propria
    /// entrada, e so a propria: nao ha disputa por este vetor.
    last_served: [max_targets]u64 = @splat(0),

    /// Publica um pedido e devolve o numero dele.
    ///
    /// O chamador segura o lock do modulo: dois pedidos no ar ao mesmo tempo
    /// teriam duas contagens de pendentes e nenhuma delas fecharia.
    pub fn begin(self: *Mailbox, scope: Scope, address: u64, targets: u32) Request {
        self.scope = scope;
        self.address = address;

        const generation = self.generation.load(.monotonic) + 1;
        self.started += 1;
        // O pendente e publicado antes da geracao: uma resposta so pode
        // chegar depois de a IPI sair, e a IPI sai depois desta funcao.
        self.pending.store(targets, .monotonic);
        self.generation.store(generation, .release);

        return .{ .scope = scope, .address = address, .generation = generation };
    }

    /// Diz se todas as CPUs que deviam responder ja responderam.
    pub fn isComplete(self: *const Mailbox) bool {
        return self.pending.load(.acquire) == 0;
    }

    /// Quantas respostas ainda faltam.
    pub fn outstanding(self: *const Mailbox) u32 {
        return self.pending.load(.acquire);
    }

    /// O pedido que esta CPU ainda nao serviu, ou null quando nao ha nada para
    /// ela — o caso da IPI reentregue, do pedido que ela ja serviu e da maquina
    /// que nao tem pedido no ar.
    pub fn latch(self: *const Mailbox, cpu_index: usize) ?Request {
        const generation = self.generation.load(.acquire);
        if (generation == 0) return null;
        if (cpu_index < max_targets and self.last_served[cpu_index] == generation) return null;
        return .{ .scope = self.scope, .address = self.address, .generation = generation };
    }

    /// Registra que esta CPU invalidou a traducao do pedido.
    ///
    /// O desconto e um compare-and-swap: um reconhecimento atrasado que chegasse
    /// depois de o remetente desistir encontraria o pendente em zero, e um
    /// decremento cego o levaria a 4294967295 — o pedido seguinte nunca
    /// fecharia.
    pub fn acknowledge(self: *Mailbox, cpu_index: usize, request: Request) Ack {
        const generation = self.generation.load(.acquire);
        if (generation == 0) return .idle;
        if (request.generation != generation) return .stale;
        if (cpu_index < max_targets and self.last_served[cpu_index] == generation) {
            return .duplicate;
        }

        if (cpu_index < max_targets) self.last_served[cpu_index] = generation;
        self.served += 1;
        self.retire();
        return .accepted;
    }

    /// Decrementa o pendente sem nunca passar por baixo de zero.
    fn retire(self: *Mailbox) void {
        var current = self.pending.load(.acquire);
        while (current != 0) {
            // `cmpxchgWeak` returns null when the swap happened and the value
            // somebody else left there when it did not.
            if (self.pending.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |observed| {
                // Somebody else decremented first: retry with what is there.
                current = observed;
            } else {
                // The swap happened, which is the one decrement this call owes.
                return;
            }
        }
    }

    /// Desiste de um pedido que ninguem respondeu a tempo.
    ///
    /// O pendente vai a zero para que o proximo pedido possa comecar, e a
    /// geracao **nao** muda: um reconhecimento que chegue depois ainda e
    /// reconhecido como deste pedido (`served` conta), mas nao desconta mais
    /// nada. A pagina ja foi invalidada na CPU que respondeu tarde; quem
    /// desistiu perdeu a garantia de que todas invalidaram.
    pub fn abandon(self: *Mailbox) void {
        if (self.pending.load(.acquire) == 0) return;
        self.pending.store(0, .release);
        self.timeouts += 1;
    }
};

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

test "um pedido so termina depois de todas as respostas" {
    var mailbox: Mailbox = .{};

    const request = mailbox.begin(.page, 0x4000_0000, 2);
    try std.testing.expectEqual(@as(u64, 1), request.generation);
    try std.testing.expectEqual(Scope.page, request.scope);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), request.address);
    try std.testing.expectEqual(@as(u32, 2), mailbox.outstanding());
    try std.testing.expect(!mailbox.isComplete());

    // A CPU 1 ainda nao serviu nada: o pedido inteiro esta para ela.
    const seen = mailbox.latch(1).?;
    try std.testing.expectEqual(request.generation, seen.generation);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), seen.address);
    try std.testing.expectEqual(Ack.accepted, mailbox.acknowledge(1, seen));

    try std.testing.expectEqual(@as(u32, 1), mailbox.outstanding());
    try std.testing.expect(!mailbox.isComplete());

    const seen_two = mailbox.latch(2).?;
    try std.testing.expectEqual(Ack.accepted, mailbox.acknowledge(2, seen_two));

    try std.testing.expectEqual(@as(u32, 0), mailbox.outstanding());
    try std.testing.expect(mailbox.isComplete());
    try std.testing.expectEqual(@as(u64, 2), mailbox.served);
    try std.testing.expectEqual(@as(u64, 1), mailbox.started);
}

test "a mesma CPU nao serve o mesmo pedido duas vezes" {
    var mailbox: Mailbox = .{};

    const request = mailbox.begin(.page, 0x2000, 2);
    const seen = mailbox.latch(1).?;
    try std.testing.expectEqual(Ack.accepted, mailbox.acknowledge(1, seen));

    // A IPI reentregue nao tem o que fazer: a traducao ja foi invalidada, e um
    // segundo desconto fecharia o pedido com uma CPU devendo resposta.
    try std.testing.expectEqual(@as(?Request, null), mailbox.latch(1));
    try std.testing.expectEqual(Ack.duplicate, mailbox.acknowledge(1, seen));
    try std.testing.expectEqual(@as(u32, 1), mailbox.outstanding());
    try std.testing.expectEqual(request.generation, mailbox.generation.load(.acquire));
}

test "um pedido abandonado conta o tempo e nao aceita desconto do atrasado" {
    var mailbox: Mailbox = .{};

    _ = mailbox.begin(.all, 0, 1);
    try std.testing.expectEqual(@as(u32, 1), mailbox.outstanding());

    mailbox.abandon();
    try std.testing.expectEqual(@as(u64, 1), mailbox.timeouts);
    try std.testing.expectEqual(@as(u32, 0), mailbox.outstanding());
    try std.testing.expect(mailbox.isComplete());

    // O reconhecimento atrasado continua sendo deste pedido (a CPU invalidou de
    // verdade), mas nao desconta: sem o compare-and-swap o contador daria a
    // volta e o pedido seguinte nunca fecharia.
    const late: Request = .{ .scope = .all, .address = 0, .generation = 1 };
    try std.testing.expectEqual(Ack.accepted, mailbox.acknowledge(1, late));
    try std.testing.expectEqual(@as(u32, 0), mailbox.outstanding());

    // Um segundo abandono sem pedido no ar nao conta outro tempo.
    mailbox.abandon();
    try std.testing.expectEqual(@as(u64, 1), mailbox.timeouts);
}

test "o pedido seguinte tem numero novo e o antigo vira obsoleto" {
    var mailbox: Mailbox = .{};

    const first = mailbox.begin(.page, 0x1000, 1);
    const second = mailbox.begin(.page, 0x9000, 1);

    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectEqual(@as(u64, 0x9000), second.address);
    // A CPU 1 serviu o primeiro pedido? Nao: ela ainda nao tinha nem olhado. O
    // que ela ve agora e o segundo, e so ele.
    const seen = mailbox.latch(1).?;
    try std.testing.expectEqual(second.generation, seen.generation);

    // O reconhecimento do pedido velho nao vale mais nada.
    try std.testing.expectEqual(Ack.stale, mailbox.acknowledge(2, first));
    try std.testing.expectEqual(@as(u32, 1), mailbox.outstanding());
}

test "uma caixa vazia nao tem pedido para ninguem" {
    var mailbox: Mailbox = .{};

    try std.testing.expectEqual(@as(?Request, null), mailbox.latch(1));
    try std.testing.expectEqual(
        Ack.idle,
        mailbox.acknowledge(1, .{ .generation = 1 }),
    );
    try std.testing.expect(mailbox.isComplete());
}
