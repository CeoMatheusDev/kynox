//************************************************************************//
//  msi.zig                                                               //
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

//! A interrupcao que o proprio dispositivo entrega (MSI).
//!
//! Uma linha do 8259 ou uma entrada do I/O APIC custa um fio: dois dispositivos
//! que dividem a linha obrigam o kernel a perguntar quem interrompeu, e um
//! dispositivo que nao esta na placa nao interrompe nada. A MSI troca o fio por
//! uma escrita na memoria: o dispositivo escreve um endereco e um dado que o
//! APIC local reconhece como uma interrupcao destinada a uma CPU e a um vetor.
//!
//! A capability (id 0x05) ja era percorrida pela lista do espaco de
//! configuracao (`pci.CapabilityIterator`) e nada a usava. Este modulo interpreta
//! o `Message Control`, calcula a mensagem e onde os registradores dela moram, e
//! programa a capability — sem supor que o dispositivo seja um VirtIO, que o
//! endereco esteja alinhado de um jeito especifico ou que todas as funcoes
//! implementem os mesmos bits.
//!
//! O que este modulo **nao** faz: decidir quando habilitar. Programar a
//! capability desliga a INTx daquele dispositivo — a especificacao exige —, e um
//! driver que ainda depende da linha classica ficaria sem interrupcao. A escolha
//! e do boot (`-Dmsi-delivery=true`), e o padrao continua a linha do 8259.

const std = @import("std");
const pci = @import("pci.zig");

/// Identificador da capability de MSI.
pub const capability_id: u8 = 0x05;

/// Identificador da capability de MSI-X.
///
/// MSI-X nao usa estes registradores: os vetores moram em uma tabela na memoria
/// do dispositivo. O identificador existe aqui para que o boot possa dizer qual
/// das duas o dispositivo oferece, em vez de dizer apenas "nao".
pub const capability_id_msix: u8 = 0x11;

/// A base do endereco da mensagem, como a especificacao define.
///
/// O campo de destino da mensagem (bits 19:12 do endereco) leva o APIC id da CPU,
/// e tudo abaixo de 0xFEE0_0000 e reservado.
pub const address_base: u32 = 0xFEE0_0000;

/// O primeiro vetor que um dispositivo pode receber.
///
/// Os vetores abaixo deste pertencem ao kernel: 0..31 sao excecoes, 32..47 sao
/// as linhas de hardware e 64..67 sao o timer local, o reschedule, o shootdown e
/// a parada. Um dispositivo com um desses vetores entregaria uma interrupcao que
/// o kernel leria como uma excecao ou como outro evento.
pub const first_device_vector: u8 = 68;

/// Os bits de `Message Control`, no offset 2 da capability.
pub const Control = struct {
    /// Habilita a MSI. A especificacao manda escreve-lo por ultimo: o
    /// dispositivo pode entregar uma mensagem no instante em que o bit sobe, e
    /// os registradores precisam ja estar certos.
    pub const enable: u16 = 1 << 0;
    /// Quantos vetores o dispositivo **pode** usar (3 bits, codificados como
    /// potencia de dois).
    pub const capable_mask: u16 = 0x000E;
    pub const capable_shift: u4 = 1;
    /// Quantos vetores ele **vai** usar (3 bits, a mesma codificacao).
    pub const allocated_mask: u16 = 0x0070;
    pub const allocated_shift: u4 = 4;
    /// A capability tem o endereco superior de 32 bits.
    pub const address_64: u16 = 1 << 7;
    /// A capability mascara vetor por vetor.
    pub const per_vector_masking: u16 = 1 << 8;
};

/// Quantos vetores um campo de 3 bits descreve: 1 << valor.
pub fn vectorCount(field: u16) u8 {
    const bits: u3 = @truncate(field & 0x7);
    return @as(u8, 1) << bits;
}

/// Quantos vetores o dispositivo declara poder usar.
pub fn capableVectors(control: u16) u8 {
    return vectorCount((control & Control.capable_mask) >> Control.capable_shift);
}

/// Quantos vetores o dispositivo foi autorizado a usar.
pub fn allocatedVectors(control: u16) u8 {
    return vectorCount((control & Control.allocated_mask) >> Control.allocated_shift);
}

/// A mensagem que o dispositivo escreve quando interrompe.
pub const Message = struct {
    /// Os 32 bits baixos do endereco. O campo de destino mora nos bits 19:12.
    address: u32,
    /// Os 32 bits altos, quando a capability declara 64 bits de endereco.
    upper: u32 = 0,
    /// O dado: o vetor nos bits 7:0, com entrega fixa, borda e destino fisico.
    data: u32,
    /// O APIC id da CPU que recebe, guardado para o relatorio.
    destination_apic_id: u8 = 0,
    /// O vetor, guardado para o relatorio.
    vector: u8 = 0,
};

/// Por que uma mensagem foi recusada.
pub const MessageError = error{
    /// O vetor pertence ao kernel: excecoes, linhas de hardware ou os vetores
    /// que o kernel inventou acima delas.
    VectorBelongsToKernel,
};

/// Monta a mensagem de uma MSI para uma CPU e um vetor.
///
/// O `data` fica com os bits que a especificacao define como "entrega fixa,
/// borda, destino fisico": o resto e zero, e nao um valor herdado de outro
/// dispositivo. Um vetor dos que o kernel usa e recusado: entregar a um
/// dispositivo o vetor 8 faria o kernel tratar um pacote de rede como falha
/// dupla.
pub fn build(destination_apic_id: u8, vector: u8) MessageError!Message {
    if (vector < first_device_vector) return error.VectorBelongsToKernel;
    if (vector == 0xFF) return error.VectorBelongsToKernel; // o vetor de "espurio"

    return .{
        .address = address_base | (@as(u32, destination_apic_id) << 12),
        .upper = 0,
        .data = @as(u32, vector),
        .destination_apic_id = destination_apic_id,
        .vector = vector,
    };
}

/// Onde os registradores da mensagem moram dentro da capability.
///
/// Os offsets sao relativos ao inicio do espaco de configuracao, como tudo o
/// mais neste modulo. Os quatro bytes de `Message Address` comecam no offset 4 da
/// capability; o resto depende de dois bits do `Message Control`.
pub const Layout = struct {
    /// `Message Address`, 32 bits.
    address: u8,
    /// `Message Upper Address`, 32 bits, so quando a capability declara 64.
    upper: ?u8,
    /// `Message Data`, 16 bits no inicio de um dword.
    data: u8,
    /// Os bits de mascara, quando a capability mascara vetor por vetor.
    mask: ?u8,
};

/// Por que uma capability foi recusada.
pub const LayoutError = error{
    /// O identificador nao e o da MSI.
    NotMsiCapability,
    /// Um dos registradores cairia fora do espaco de configuracao.
    OutsideConfigSpace,
};

/// Calcula onde os registradores da mensagem moram.
///
/// A capability comeca em um offset alinhado em dword, garantido pelo percurso
/// da lista (`pci.CapabilityIterator` recusa um ponteiro desalinhado), e por
/// isso `offset + 2` — o `Message Control` — cai dentro do primeiro dword.
pub fn layout(capability: pci.Capability, control: u16) LayoutError!Layout {
    if (capability.id != capability_id) return error.NotMsiCapability;

    const is_64 = (control & Control.address_64) != 0;

    // A aritmetica e feita no tamanho do espaco, e nao no byte do offset: uma
    // capability no fim do espaco somaria alem de 255 e o resultado voltaria ao
    // comeco em silencio, que e o pior desfecho possivel para um registrador.
    const base: usize = capability.offset;
    const address = base + 4;
    const upper: ?usize = if (is_64) base + 8 else null;
    const data = base + (if (is_64) @as(usize, 12) else 8);
    // Uma capability de 64 bits ja ocupou 12 bytes e a mascara vem em 16; a de
    // 32 bits termina o dado em 8 e a mascara vem em 12.
    const mask: ?usize = if ((control & Control.per_vector_masking) != 0)
        base + (if (is_64) @as(usize, 16) else 12)
    else
        null;

    // O ultimo registrador tem de caber: uma capability no fim do espaco nao
    // pode ser programada, e dizer isso aqui e melhor que escrever em cima do
    // comeco da proxima.
    const last = mask orelse data;
    if (last + 4 > pci.config_space_size) return error.OutsideConfigSpace;

    return .{
        .address = @intCast(address),
        .upper = if (upper) |value| @intCast(value) else null,
        .data = @intCast(data),
        .mask = if (mask) |value| @intCast(value) else null,
    };
}

/// Quantos vetores o kernel vai usar de um dispositivo.
///
/// O pedido tem de ser potencia de dois e caber no que o dispositivo declara.
/// Um numero que nao e potencia de dois nao pode ser expresso no campo de tres
/// bits, e arredondar para cima daria ao dispositivo um vetor que o kernel nao
/// reservou.
pub const AllocationError = error{
    NotPowerOfTwo,
    MoreThanDeviceOffers,
    None,
};

/// Confere o pedido e devolve o `Message Control` com o campo de vetores
/// alocados preenchido (sem o bit de habilitacao).
pub fn allocate(control: u16, requested: u8) AllocationError!u16 {
    if (requested == 0) return error.None;
    if (!std.math.isPowerOfTwo(requested)) return error.NotPowerOfTwo;
    if (requested > capableVectors(control)) return error.MoreThanDeviceOffers;

    const bits: u16 = @intCast(std.math.log2_int(u8, requested));
    return (control & ~Control.allocated_mask) | (bits << Control.allocated_shift);
}

/// O que foi escrito na capability.
pub const Programmed = struct {
    message: Message,
    /// O `Message Control` final, com o bit de habilitacao.
    control: u16,
    layout: Layout,
    /// Quantos vetores foram autorizados.
    vectors: u8,
};

/// Por que a programacao falhou.
pub const ProgramError = LayoutError || AllocationError || MessageError;

/// Programa a capability de MSI de uma funcao.
///
/// A ordem das escritas e a da especificacao: endereco, endereco superior, dado,
/// e o `Message Control` por ultimo com o bit de habilitacao — o dispositivo pode
/// entregar uma mensagem no instante em que o bit sobe, e nesse instante tudo o
/// mais tem de estar no lugar.
///
/// A leitura do `Message Control` acontece no dword que contem o inicio da
/// capability, porque o espaco de configuracao legado so aceita acesso de 32
/// bits alinhado. Escrever o dword de volta preserva o identificador e o
/// ponteiro da lista, que estao nos dois primeiros bytes.
pub fn programWith(
    access: pci.ConfigAccess,
    capability: pci.Capability,
    destination_apic_id: u8,
    vector: u8,
    requested_vectors: u8,
) ProgramError!Programmed {
    const control_dword = access.read(capability.offset);
    const control: u16 = @truncate(control_dword >> 16);

    const places = try layout(capability, control);
    const message = try build(destination_apic_id, vector);
    const allocated = try allocate(control, requested_vectors);

    access.write(places.address, message.address);
    if (places.upper) |upper_offset| access.write(upper_offset, message.upper);
    // O dado ocupa 16 bits no inicio de um dword; o resto do dword e reservado
    // e fica em zero.
    access.write(places.data & 0xFC, message.data & 0xFFFF);

    const final_control = allocated | Control.enable;
    access.write(
        capability.offset,
        (control_dword & 0x0000_FFFF) | (@as(u32, final_control) << 16),
    );

    return .{
        .message = message,
        .control = final_control,
        .layout = places,
        .vectors = requested_vectors,
    };
}

/// A capability de MSI de uma funcao, ou null quando ela nao existe.
///
/// Uma lista de capabilities corrompida tambem devolve null: o dispositivo nao
/// pode ser programado, e o boot reporta isso como "sem MSI" em vez de parar por
/// causa de um dispositivo que talvez nem seja usado.
pub fn find(reader: pci.Reader) ?pci.Capability {
    return pci.findCapability(reader, capability_id) catch null;
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

/// Espaco de configuracao em memoria, com leitura e escrita de dword.
const Image = struct {
    bytes: [pci.config_space_size]u8 = @splat(0),

    fn read(ctx: *anyopaque, offset: u8) u32 {
        const self: *Image = @ptrCast(@alignCast(ctx));
        const base = offset & 0xFC;
        if (@as(usize, base) + 4 > pci.config_space_size) return 0;
        const b0: u32 = self.bytes[base];
        const b1: u32 = self.bytes[base + 1];
        const b2: u32 = self.bytes[base + 2];
        const b3: u32 = self.bytes[base + 3];
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
    }

    fn write(ctx: *anyopaque, offset: u8, value: u32) void {
        const self: *Image = @ptrCast(@alignCast(ctx));
        const base = offset & 0xFC;
        if (@as(usize, base) + 4 > pci.config_space_size) return;
        self.bytes[base] = @truncate(value);
        self.bytes[base + 1] = @truncate(value >> 8);
        self.bytes[base + 2] = @truncate(value >> 16);
        self.bytes[base + 3] = @truncate(value >> 24);
    }

    fn access(self: *Image) pci.ConfigAccess {
        return .{ .ctx = @ptrCast(self), .read_fn = read, .write_fn = write };
    }

    /// Uma leitura byte a byte, que e o que o percurso de capabilities usa.
    fn reader(self: *const Image) pci.Reader {
        return .{ .ctx = @ptrCast(self), .read_byte = readByte };
    }

    fn readByte(ctx: *const anyopaque, offset: u8) u8 {
        const self: *const Image = @ptrCast(@alignCast(ctx));
        return self.bytes[offset];
    }

    fn word(self: *const Image, offset: u8) u16 {
        return @as(u16, self.bytes[offset]) | (@as(u16, self.bytes[offset + 1]) << 8);
    }

    fn dword(self: *const Image, offset: u8) u32 {
        const base = offset & 0xFC;
        return @as(u32, self.bytes[base]) |
            (@as(u32, self.bytes[base + 1]) << 8) |
            (@as(u32, self.bytes[base + 2]) << 16) |
            (@as(u32, self.bytes[base + 3]) << 24);
    }
};

/// Monta uma capability de MSI no offset 0x40 de uma imagem.
fn msiCapability(control: u16) Image {
    var image: Image = .{};
    image.bytes[0x40] = capability_id;
    image.bytes[0x41] = 0x00; // fim da lista
    image.bytes[0x42] = @truncate(control);
    image.bytes[0x43] = @truncate(control >> 8);
    return image;
}

test "a mensagem leva o APIC id da CPU e o vetor do dispositivo" {
    const message = try build(3, 80);

    // O destino mora nos bits 19:12 e o resto do endereco e o da especificacao.
    try std.testing.expectEqual(@as(u32, 0xFEE0_0000 | (3 << 12)), message.address);
    try std.testing.expectEqual(@as(u32, 80), message.data);
    try std.testing.expectEqual(@as(u32, 0), message.upper);
    try std.testing.expectEqual(@as(u8, 3), message.destination_apic_id);
    try std.testing.expectEqual(@as(u8, 80), message.vector);
}

test "um vetor do kernel nao pode ser entregue a um dispositivo" {
    // Cada um destes vetores ja tem um significado: uma excecao, uma linha de
    // hardware, o timer local, o reschedule, o shootdown ou a parada.
    for ([_]u8{ 0, 8, 32, 47, 64, 65, 66, 67 }) |vector| {
        try std.testing.expectError(error.VectorBelongsToKernel, build(1, vector));
    }

    // O primeiro vetor livre e o primeiro que a funcao aceita.
    const message = try build(1, first_device_vector);
    try std.testing.expectEqual(first_device_vector, message.vector);

    // O vetor de "espurio" tambem nao e de um dispositivo.
    try std.testing.expectError(error.VectorBelongsToKernel, build(1, 0xFF));
}

test "os campos de vetores sao potencias de dois de tres bits" {
    // Um controle que declara 4 vetores (bits 0b010 = 1, 1 << 1 = 2? nao:
    // 0b010 vale 2 e descreve 4). O comentario existe porque este e o campo
    // mais facil de ler errado do `Message Control`.
    const declares_four: u16 = 0b010 << Control.capable_shift;
    try std.testing.expectEqual(@as(u8, 4), capableVectors(declares_four));

    const declares_one: u16 = 0;
    try std.testing.expectEqual(@as(u8, 1), capableVectors(declares_one));

    // O campo alocado usa a mesma codificacao, com o deslocamento 4.
    const allocated: u16 = 0b011 << Control.allocated_shift;
    try std.testing.expectEqual(@as(u8, 8), allocatedVectors(allocated));
}

test "o pedido de vetores tem de ser potencia de dois e caber no dispositivo" {
    const offers_four: u16 = 0b010 << Control.capable_shift;

    // Um vetor: o campo fica zero.
    const one = try allocate(offers_four, 1);
    try std.testing.expectEqual(@as(u16, 0), one & Control.allocated_mask);
    // Quatro: 0b010 no campo.
    const four = try allocate(offers_four, 4);
    try std.testing.expectEqual(@as(u16, 0b010 << Control.allocated_shift), four & Control.allocated_mask);

    // Tres nao cabe em tres bits sem arredondar, e arredondar daria ao
    // dispositivo um vetor que o kernel nao reservou.
    try std.testing.expectError(error.NotPowerOfTwo, allocate(offers_four, 3));
    // Oito e potencia de dois, e o dispositivo so oferece quatro.
    try std.testing.expectError(error.MoreThanDeviceOffers, allocate(offers_four, 8));
    // Zero vetor nao e um pedido.
    try std.testing.expectError(error.None, allocate(offers_four, 0));
}

test "o layout depende dos bits de 64 bits e de mascara" {
    const capability: pci.Capability = .{ .id = capability_id, .offset = 0x40, .length = null };

    // 32 bits, sem mascara: endereco em 0x44, dado em 0x48.
    const small = try layout(capability, 0);
    try std.testing.expectEqual(@as(u8, 0x44), small.address);
    try std.testing.expectEqual(@as(?u8, null), small.upper);
    try std.testing.expectEqual(@as(u8, 0x48), small.data);
    try std.testing.expectEqual(@as(?u8, null), small.mask);

    // 64 bits: endereco superior em 0x48 empurra o dado para 0x4C.
    const wide = try layout(capability, Control.address_64);
    try std.testing.expectEqual(@as(?u8, 0x48), wide.upper);
    try std.testing.expectEqual(@as(u8, 0x4C), wide.data);

    // Mascara por vetor: 0x4C depois do dado de 32 bits, 0x50 depois do de 64.
    const masked = try layout(capability, Control.per_vector_masking);
    try std.testing.expectEqual(@as(?u8, 0x4C), masked.mask);

    const wide_masked = try layout(capability, Control.address_64 | Control.per_vector_masking);
    try std.testing.expectEqual(@as(?u8, 0x50), wide_masked.mask);

    // Outra capability nao e programavel por este modulo.
    const msix: pci.Capability = .{ .id = capability_id_msix, .offset = 0x60, .length = null };
    try std.testing.expectError(error.NotMsiCapability, layout(msix, 0));
}

test "uma capability no fim do espaco nao pode ser programada" {
    // Sem espaco para a mascara depois do dado: escrever ali cairia em cima da
    // proxima coisa que o espaco de configuracao carrega.
    const capability: pci.Capability = .{ .id = capability_id, .offset = 0xF8, .length = null };
    try std.testing.expectError(error.OutsideConfigSpace, layout(capability, 0));
}

test "programar uma MSI de 32 bits escreve endereco, dado e o bit de habilitacao" {
    var image = msiCapability(0b010 << Control.capable_shift); // quatro vetores
    const access = image.access();
    const capability: pci.Capability = .{ .id = capability_id, .offset = 0x40, .length = null };

    const programmed = try programWith(access, capability, 2, 0x50, 4);

    // O endereco da mensagem no registrador do offset 4.
    try std.testing.expectEqual(@as(u32, 0xFEE0_0000 | (2 << 12)), image.dword(0x44));
    // O dado (16 bits) no offset 8.
    try std.testing.expectEqual(@as(u16, 0x50), image.word(0x48));
    // O identificador e o ponteiro da lista continuam onde estavam: escrever o
    // dword do controle nao pode apagar o comeco da capability.
    try std.testing.expectEqual(capability_id, image.bytes[0x40]);
    try std.testing.expectEqual(@as(u8, 0), image.bytes[0x41]);

    // O controle: habilitado, com 0b010 no campo de vetores alocados.
    try std.testing.expect(programmed.control & Control.enable != 0);
    try std.testing.expectEqual(@as(u16, 0b010 << Control.allocated_shift), programmed.control & Control.allocated_mask);
    try std.testing.expectEqual(programmed.control, image.word(0x42));
    try std.testing.expectEqual(@as(u8, 0x50), programmed.message.vector);
}

test "programar uma MSI de 64 bits escreve tambem o endereco superior" {
    var image = msiCapability(Control.address_64);
    const access = image.access();
    const capability: pci.Capability = .{ .id = capability_id, .offset = 0x40, .length = null };

    _ = try programWith(access, capability, 5, 0x60, 1);

    try std.testing.expectEqual(@as(u32, 0xFEE0_0000 | (5 << 12)), image.dword(0x44));
    // O endereco superior existe, foi escrito, e e zero no APIC xAPIC.
    try std.testing.expectEqual(@as(u32, 0), image.dword(0x48));
    try std.testing.expectEqual(@as(u16, 0x60), image.word(0x4C));
}

test "uma recusa nao escreve nada no espaco de configuracao" {
    var image = msiCapability(0);
    const before = image.bytes;
    const access = image.access();
    const capability: pci.Capability = .{ .id = capability_id, .offset = 0x40, .length = null };

    // Um vetor do kernel, um numero de vetores que nao e potencia de dois, e um
    // pedido maior do que o dispositivo declara: nenhum deles pode deixar a
    // capability meio programada.
    try std.testing.expectError(error.VectorBelongsToKernel, programWith(access, capability, 0, 8, 1));
    try std.testing.expectError(error.NotPowerOfTwo, programWith(access, capability, 0, 0x50, 3));
    try std.testing.expectError(error.MoreThanDeviceOffers, programWith(access, capability, 0, 0x50, 2));

    try std.testing.expectEqualSlices(u8, &before, &image.bytes);
}

test "a capability de MSI e encontrada pela lista, e a de MSI-X nao" {
    var image: Image = .{};
    // Status com o bit 4 (lista de capabilities), ponteiro para 0x50.
    image.bytes[0x06] = 0x10;
    image.bytes[0x34] = 0x50;
    // 0x50: MSI-X (0x11), proxima em 0x60.
    image.bytes[0x50] = capability_id_msix;
    image.bytes[0x51] = 0x60;
    // 0x60: MSI (0x05), fim da lista.
    image.bytes[0x60] = capability_id;
    image.bytes[0x61] = 0x00;

    const found = find(image.reader());
    try std.testing.expectEqual(@as(?pci.Capability, .{ .id = capability_id, .offset = 0x60, .length = null }), found);

    // Sem lista nenhuma, a resposta e null e nao um erro que pararia o boot.
    var bare: Image = .{};
    try std.testing.expectEqual(@as(?pci.Capability, null), find(bare.reader()));
}
