//************************************************************************//
//  virtqueue_probe.zig                                                   //
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

//! Sonda de layout da fila dividida do VirtIO (ADR-0002, passo 2).
//!
//! A sonda existia dentro de `kernel/main.zig` e exercitava a implementação
//! legada da fila, que o driver não programava — o marcador provava uma
//! estrutura que o dispositivo nunca via. Agora ela roda sobre
//! `kvdi.virtqueue`, a mesma implementação que o virtio-blk usa, e o
//! resultado é um valor puro que o boot imprime.
//!
//! O módulo não escreve no console: ele devolve números e um texto, e o
//! chamador imprime. Essa separação é o primeiro passo do ADR-0001 aplicado a
//! uma sonda que não depende de hardware, e permite que o host teste as
//! mesmas propriedades que o boot imprime.
//!
//! O texto do marcador é contrato com `tests/integration/boot-qemu.sh` e
//! `tests/integration/log-assertions-test.sh`: a linha completa é
//!
//!   `[KNK] virtio: split queue layout ok desc=0 avail=256 used=296 size=432`

const std = @import("std");
const virtqueue = @import("virtqueue.zig");

/// Prefixo do marcador impresso pelo boot.
pub const prefix = "[KNK] virtio: split queue layout ok";

/// Número de descritores da fila que a sonda monta.
///
/// É a mesma quantidade que o virtio-blk do QEMU anuncia, e cabe na memória
/// estática que o kernel reserva para a sonda.
pub const queue_size: u16 = 16;

/// Bytes da faixa de prova, derivados do layout: o chamador precisa garantir
/// pelo menos `total_size` bytes.
pub const storage_bytes: u32 = 4096;

/// Erros da sonda: os da fila mais a falha de consistência do índice.
pub const Error = virtqueue.Error || error{
    /// O índice publicado não é o esperado; o contrato da fila foi violado.
    UnexpectedAvailableIndex,
};

/// Resultado de uma sonda bem-sucedida.
pub const Result = struct {
    descriptor_offset: u32,
    available_offset: u32,
    used_offset: u32,
    total_size: u32,
    available_index: u16,

    /// Escreve `desc=<n> avail=<n> used=<n> size=<n>` em `buffer`.
    ///
    /// O buffer precisa ter `format_length` bytes; a função devolve a fatia
    /// escrita e nunca transborda. Um buffer menor devolve a string vazia,
    /// porque truncar o marcador produziria uma linha que os scripts de
    /// verificação não reconheceriam pela metade.
    pub fn format(self: Result, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "desc={d} avail={d} used={d} size={d}", .{
            self.descriptor_offset,
            self.available_offset,
            self.used_offset,
            self.total_size,
        }) catch "";
    }

    /// Tamanho máximo de `format`, para dimensionar o buffer do chamador.
    pub const format_length = 96;
};

/// Monta a fila sobre `memory`, publica uma cadeia e devolve o layout usado.
///
/// `physical` é o endereço físico da mesma faixa (identidade no boot). A
/// sonda não toca em dispositivo algum: ela exercita a aritmética da fila e o
/// caminho de publicação em memória.
pub fn run(memory: []u8, physical: u64) Error!Result {
    const layout = try virtqueue.Layout.compute(queue_size);

    var queue = try virtqueue.Queue(queue_size).init(.{
        .physical = physical,
        .bytes = memory,
    }, queue_size);

    const head = try queue.allocate();
    try queue.setBuffer(head, 0x1000, 512);
    try queue.publish(head);

    const index = queue.availableIndex();
    if (index != 1) return error.UnexpectedAvailableIndex;

    return .{
        .descriptor_offset = layout.descriptor_offset,
        .available_offset = layout.available_offset,
        .used_offset = layout.used_offset,
        .total_size = layout.total_size,
        .available_index = index,
    };
}

test "the probe reports the KVDI layout of a sixteen entry queue" {
    var storage: [storage_bytes]u8 align(16) = undefined;
    const result = try run(&storage, @intFromPtr(&storage));

    try std.testing.expectEqual(@as(u32, 0), result.descriptor_offset);
    try std.testing.expectEqual(@as(u32, 256), result.available_offset);
    // 16 descriptors x 16 B = 256 B of descriptor table, 6 + 2*16 = 38 B of
    // available ring, aligned forward to 4 -> used ring at 296, then
    // 6 + 8*16 = 134 B of used ring, aligned forward to 16 -> 432 B total.
    try std.testing.expectEqual(@as(u32, 296), result.used_offset);
    try std.testing.expectEqual(@as(u32, 432), result.total_size);
    try std.testing.expectEqual(@as(u16, 1), result.available_index);
}

test "the rendered text is the serial marker asserted by the boot suite" {
    var storage: [storage_bytes]u8 align(16) = undefined;
    const result = try run(&storage, @intFromPtr(&storage));

    var buffer: [Result.format_length]u8 = undefined;
    const text = result.format(&buffer);
    try std.testing.expectEqualStrings(
        "desc=0 avail=256 used=296 size=432",
        text,
    );
}

test "the marker prefix is the one the integration scripts require" {
    try std.testing.expectEqualStrings(
        "[KNK] virtio: split queue layout ok",
        prefix,
    );
}

test "the probe refuses memory that cannot hold the layout" {
    var small: [64]u8 align(16) = undefined;
    try std.testing.expectError(
        error.MemoryTooSmall,
        run(&small, @intFromPtr(&small)),
    );
}

test "the probe refuses an unaligned physical address" {
    var storage: [storage_bytes]u8 align(16) = undefined;
    try std.testing.expectError(
        error.MisalignedMemory,
        run(&storage, @intFromPtr(&storage) + 8),
    );
}

test "the format never writes past the buffer it was given" {
    const result: Result = .{
        .descriptor_offset = 0,
        .available_offset = 256,
        .used_offset = 304,
        .total_size = 448,
        .available_index = 1,
    };
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", result.format(&tiny));
}
