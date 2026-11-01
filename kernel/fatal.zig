//************************************************************************//
//  fatal.zig                                                             //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                   //
//             https://github.com/CeoMatheusDev/Kynox                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 Kynox - All Rights Reserved.                       //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! O que o kernel faz quando nao ha o que fazer.
//!
//! Uma falha que para so o processador que a encontrou deixa a maquina num
//! estado pior do que parar inteira: as outras CPUs continuam escrevendo no
//! mesmo port serial, o relatorio da falha sai intercalado com o trabalho
//! normal, e um defeito que aconteceu uma vez vira um defeito impossivel de
//! reproduzir. Parar a maquina inteira comeca por avisar os outros
//! processadores (`smp.stopOtherCpus`, vetor 67) e termina parando este.
//!
//! A ordem e deliberada: o aviso sai **antes** da ultima linha, para que a
//! mensagem de quem parou seja a ultima coisa escrita, e nao mais uma linha no
//! meio de um fluxo que continua.
//!
//! Este modulo nao aloca memoria: ele roda no caminho da falha, onde o
//! alocador pode ser justamente o que quebrou.

const kynox = @import("kynox_shared");
const smp = @import("arch/x86_64/smp.zig");

/// Para a maquina e diz por que.
///
/// O `reason` e uma linha curta em ingles, como o resto do log do kernel.
pub fn stopTheMachine(reason: []const u8) noreturn {
    kynox.serial.printLine("[KNK] FATAL: {s}", .{reason});
    finish();
}

/// Para a maquina quando o motivo ja foi impresso por quem chamou.
///
/// A maioria das falhas do boot imprime a propria linha (com um nome de erro,
/// um endereco, o valor esperado); esta funcao acrescenta o que falta — o aviso
/// as outras CPUs e a contagem de quem foi avisado — sem repetir o motivo.
pub fn stopAfterReport() noreturn {
    finish();
}

fn finish() noreturn {
    const report = smp.stopOtherCpus();

    var buffer: [160]u8 = undefined;
    kynox.serial.printLine("[KNK] panic: {s}", .{smp.describeStop(report, &buffer)});
    kynox.serial.printLine("[KNK] panic: this processor stops here", .{});

    kynox.port.haltForever();
}

// This module has no tests of its own, and not because it was forgotten: it is a
// printer and a halt. The formatting it prints is tested where it is produced
// (`smp.describeStop`), and a host has neither a serial port to print to nor a
// processor to stop.
