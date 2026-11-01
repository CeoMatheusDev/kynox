//************************************************************************//
//  msix.zig                                                              //
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

//! MSI-X: uma tabela de mensagens na memoria do dispositivo.
//!
//! A MSI (`msi.zig`) tem os registradores da mensagem dentro do espaco de
//! configuracao: uma funcao, um endereco, um dado. A MSI-X muda o lugar — as
//! mensagens moram em uma **tabela na memoria do dispositivo**, apontada por um
//! BAR — e ganha, em troca, um vetor independente por entrada, mascaramento por
//! vetor e o bit que mascara a funcao inteira.
//!
//! A diferenca pratica que justifica a tabela: um dispositivo com varias filas
//! pode dar a cada fila o proprio vetor, e o kernel nao precisa mais perguntar
//! "qual fila foi?" depois de cada interrupcao.
//!
//! Este modulo interpreta a capability (tamanho da tabela, BIR e offset da
//! tabela e da PBA) e escreve entradas em uma tabela ja mapeada. Ele **nao**
//! mapeia o BAR: quem chama entrega a janela da tabela como uma fatia de bytes,
//! e e essa separacao que deixa a codificacao ser testada no host com uma tabela
//! simulada, sem hardware nenhum.
//!
//! O que o modulo recusa, e por que:
//!
//!   * um BIR que nomeia um BAR de I/O — a tabela e memoria, e um BAR de I/O
//!     nao aponta para memoria;
//!   * um BIR de um BAR ausente, ou uma tabela que nao cabe no tamanho do BAR;
//!   * um vetor que pertence ao kernel (abaixo de `msi.first_device_vector`) ou
//!     o vetor de "espurio", 0xFF.

const std = @import("std");
const pci = @import("pci.zig");
const msi = @import("msi.zig");

/// Identificador da capability de MSI-X.
pub const capability_id: u8 = 0x11;

/// O tamanho de uma entrada da tabela, em bytes.
pub const entry_size: u32 = 16;

/// Quantos BARs uma funcao PCI tem.
const bar_count = pci.bar_count;

/// Os bits do `Message Control` da capability de MSI-X.
pub const Control = struct {
    /// O tamanho da tabela menos um (bits 10:0).
    pub const table_size_mask: u16 = 0x07FF;
    /// Mascara a funcao inteira: nenhuma entrada entrega enquanto ela estiver
    /// ligada, mesmo que a entrada esteja desmascarada.
    pub const function_mask: u16 = 1 << 14;
    /// Habilita a MSI-X. Como na MSI, e o ultimo bit a subir.
    pub const enable: u16 = 1 << 15;
};

/// Quantas entradas a tabela tem.
///
/// O campo guarda o tamanho **menos um**: uma tabela de 32 entradas declara 31.
/// Ler o campo como "quantas" daria uma entrada a menos em toda funcao — uma
/// fila do dispositivo sem vetor — e o defeito so apareceria num dispositivo com
/// mais de uma fila.
pub fn tableSize(control: u16) u16 {
    return (control & Control.table_size_mask) + 1;
}

/// Um `Table Offset`/`PBA Offset` decodificado.
pub const Location = struct {
    /// O indice do BAR que contem a tabela (0..5).
    bir: u3,
    /// O deslocamento dentro do BAR, em bytes.
    offset: u32,
};

/// Por que um `Offset/BIR` foi recusado.
pub const LocationError = error{
    /// O identificador da capability nao e o da MSI-X.
    NotMsixCapability,
    /// Um dos registradores cairia fora do espaco de configuracao.
    OutsideConfigSpace,
};

/// Le a tabela e a PBA da capability.
///
/// O dword do `Table Offset/BIR` carrega o deslocamento nos bits 31:3 e o BIR
/// nos bits 2:0; o da PBA tem o mesmo formato quatro bytes depois.
pub const Placement = struct {
    table: Location,
    pba: Location,
    vectors: u16,
    control: u16,
};

pub fn placement(capability: pci.Capability, reader: pci.Reader) LocationError!Placement {
    if (capability.id != capability_id) return error.NotMsixCapability;
    // A capability tem 12 bytes: dois do cabecalho, dois do controle, quatro da
    // tabela e quatro da PBA.
    if (@as(usize, capability.offset) + 12 > pci.config_space_size) {
        return error.OutsideConfigSpace;
    }

    const control_dword = reader.readDword(capability.offset) orelse return error.OutsideConfigSpace;
    const control: u16 = @truncate(control_dword >> 16);

    const table_word = reader.readDword(capability.offset + 4) orelse return error.OutsideConfigSpace;
    const pba_word = reader.readDword(capability.offset + 8) orelse return error.OutsideConfigSpace;

    return .{
        .table = .{ .bir = @truncate(table_word & 0x7), .offset = table_word & ~@as(u32, 0x7) },
        .pba = .{ .bir = @truncate(pba_word & 0x7), .offset = pba_word & ~@as(u32, 0x7) },
        .vectors = tableSize(control),
        .control = control,
    };
}

/// Por que a tabela nao pode estar onde a capability diz.
pub const TableError = error{
    /// O BIR aponta para um BAR que a funcao nao implementa.
    MissingBar,
    /// O BAR existe e e de espaco de I/O: a tabela e memoria.
    IoBar,
    /// A tabela nao cabe no BAR, ou o fim dela nao cabe num endereco.
    TableOutsideBar,
};

/// Confere se a tabela de uma funcao cabe no BAR que a capability nomeia.
///
/// `sizes` e o resultado de `pci.probeBarSizes`: o tamanho de cada BAR, ou nulo
/// quando ele nao existe. Um BAR de I/O e recusado mesmo que tenha tamanho — a
/// tabela e escrita pela memoria, nao por portas.
pub fn validateTable(location: Location, bars: BarInfo, sizes: pci.BarSizes) TableError!void {
    const index: usize = location.bir;
    if (index >= bar_count) return error.MissingBar;

    const bar = bars[index] orelse return error.MissingBar;
    if (bar.is_io) return error.IoBar;

    const size = sizes[index] orelse return error.MissingBar;
    const length = std.math.mul(u64, entry_size, @as(u64, 1)) catch return error.TableOutsideBar;
    _ = length;

    const end = std.math.add(u64, location.offset, entry_size) catch return error.TableOutsideBar;
    if (end > size) return error.TableOutsideBar;
}

/// O BAR a que a tabela pertence, para o relatorio do boot.
pub const BarInfo = [bar_count]?pci.Bar;

/// Uma entrada da tabela, como o dispositivo a le.
pub const Entry = struct {
    address: u32,
    upper: u32 = 0,
    data: u32,
    /// O bit 0 do `Vector Control`: ligado, a entrada nao entrega nada.
    masked: bool = true,
};

/// Por que uma entrada foi recusada.
pub const EntryError = msi.MessageError;

/// Monta a entrada de um vetor.
///
/// A mensagem e a mesma da MSI (`msi.build`), e a recusa tambem: um vetor do
/// kernel nao pode chegar a um dispositivo. A entrada nasce **mascarada**, que e
/// o estado seguro: a tabela e preenchida antes de qualquer interrupcao poder
/// sair, e o kernel desmascara uma entrada de cada vez quando o driver da fila
/// existe.
pub fn entry(destination_apic_id: u8, vector: u8) EntryError!Entry {
    const message = try msi.build(destination_apic_id, vector);
    return .{ .address = message.address, .upper = message.upper, .data = message.data, .masked = true };
}

/// Por que uma escrita na tabela foi recusada.
pub const WriteError = error{
    /// A janela da tabela nao tem bytes para a entrada pedida.
    TableTooShort,
    /// O byte de `Vector Control` da entrada nao cabe na janela.
    ControlOutsideTable,
};

/// Escreve uma entrada na janela da tabela.
///
/// A janela comeca no inicio da tabela: a entrada N ocupa os bytes N*16 ate
/// N*16+15. A funcao nao escreve fora da janela e nao toca na PBA — ela mora em
/// outro dword da capability, possivelmente em outro BAR.
pub fn writeEntry(table: []u8, index: u16, value: Entry) WriteError!void {
    const base = std.math.mul(usize, index, entry_size) catch return error.TableTooShort;
    if (base + entry_size > table.len) return error.TableTooShort;

    std.mem.writeInt(u32, table[base..][0..4], value.address, .little);
    std.mem.writeInt(u32, table[base + 4 ..][0..4], value.upper, .little);
    std.mem.writeInt(u32, table[base + 8 ..][0..4], value.data, .little);

    const control_offset = base + 12;
    if (control_offset + 4 > table.len) return error.ControlOutsideTable;
    const current = std.mem.readInt(u32, table[control_offset..][0..4], .little);
    const control = if (value.masked) current | 1 else current & ~@as(u32, 1);
    std.mem.writeInt(u32, table[control_offset..][0..4], control, .little);
}

/// Le uma entrada da janela, para o relatorio e para os testes.
pub fn readEntry(table: []const u8, index: u16) ?Entry {
    const base = std.math.mul(usize, index, entry_size) catch return null;
    if (base + entry_size > table.len) return null;

    const control = std.mem.readInt(u32, table[base + 12 ..][0..4], .little);
    return .{
        .address = std.mem.readInt(u32, table[base..][0..4], .little),
        .upper = std.mem.readInt(u32, table[base + 4 ..][0..4], .little),
        .data = std.mem.readInt(u32, table[base + 8 ..][0..4], .little),
        .masked = control & 1 != 0,
    };
}

/// Desmascara uma entrada: a fila dela passa a poder interromper.
///
/// E a operacao que fecha o caminho — e a unica que deixa o dispositivo
/// entregar. Ela e separada de `writeEntry` de proposito: preencher a tabela e
/// liberar um vetor sao duas decisoes, e a segunda so e correta quando o handler
/// daquele vetor ja existe.
pub fn unmask(table: []u8, index: u16) bool {
    const base = std.math.mul(usize, index, entry_size) catch return false;
    if (base + entry_size > table.len) return false;
    const control = std.mem.readInt(u32, table[base + 12 ..][0..4], .little);
    std.mem.writeInt(u32, table[base + 12 ..][0..4], control & ~@as(u32, 1), .little);
    return true;
}

/// Mascara uma entrada, de novo.
pub fn mask(table: []u8, index: u16) bool {
    const base = std.math.mul(usize, index, entry_size) catch return false;
    if (base + entry_size > table.len) return false;
    const control = std.mem.readInt(u32, table[base + 12 ..][0..4], .little);
    std.mem.writeInt(u32, table[base + 12 ..][0..4], control | 1, .little);
    return true;
}

/// O `Message Control` com os dois bits de estado.
///
/// A ordem de habilitacao e a que a especificacao manda, e ela e facil de errar:
/// a **funcao** fica mascarada enquanto a tabela e preenchida; depois o bit de
/// habilitacao sobe; a funcao e desmascarada por ultimo. Sem o mascaraamento da
/// funcao no meio, um dispositivo com uma fila que entrega durante o
/// preenchimento entregaria um vetor que ainda nao tem handler.
pub fn controlFor(control: u16, enabled: bool, function_masked: bool) u16 {
    var result = control & ~(Control.enable | Control.function_mask);
    if (enabled) result |= Control.enable;
    if (function_masked) result |= Control.function_mask;
    return result;
}

/// O bit do `Command` que desliga a INTx de uma funcao.
///
/// A especificacao de MSI-X exige que a INTx seja desabilitada quando a MSI-X
/// esta habilitada: com as duas ligadas o kernel receberia duas interrupcoes pelo
/// mesmo evento, uma por mensagem e uma pela linha.
pub const command_disable_intx: u16 = 1 << 10;

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

/// Uma imagem de configuracao com uma capability de MSI-X no offset 0x40.
fn capabilityImage(control: u16, table_word: u32, pba_word: u32) pci.ConfigImage {
    var image = pci.ConfigImage.zeroed();
    image.writeByte(0x40, capability_id);
    image.writeByte(0x41, 0x00);
    image.writeDword(0x40, @as(u32, capability_id) |
        (@as(u32, 0x00) << 8) |
        (@as(u32, control) << 16));
    image.writeDword(0x44, table_word);
    image.writeDword(0x48, pba_word);
    return image;
}

test "o tamanho da tabela e o campo mais um" {
    // O campo guarda o tamanho menos um: 31 sao 32 entradas, e nao 31.
    try std.testing.expectEqual(@as(u16, 32), tableSize(31));
    try std.testing.expectEqual(@as(u16, 1), tableSize(0));
    try std.testing.expectEqual(@as(u16, 2048), tableSize(Control.table_size_mask));

    // Os bits altos nao fazem parte do tamanho: a funcao mascarada e o bit de
    // habilitacao continuam no controle e nao podem inflar a tabela.
    try std.testing.expectEqual(@as(u16, 8), tableSize(7 | Control.enable | Control.function_mask));
}

test "a tabela e a PBA sao lidas nos dois dwords da capability" {
    // Tabela: BIR 3, offset 0x2000. PBA: BIR 4, offset 0x3000.
    const image = capabilityImage(31, 0x2000 | 3, 0x3000 | 4);
    const capability: pci.Capability = .{ .id = capability_id, .offset = 0x40, .length = null };

    const places = try placement(capability, image.reader());
    try std.testing.expectEqual(@as(u3, 3), places.table.bir);
    try std.testing.expectEqual(@as(u32, 0x2000), places.table.offset);
    try std.testing.expectEqual(@as(u3, 4), places.pba.bir);
    try std.testing.expectEqual(@as(u32, 0x3000), places.pba.offset);
    try std.testing.expectEqual(@as(u16, 32), places.vectors);

    // Os tres bits baixos sao o BIR, e o deslocamento e o resto do dword: um
    // offset que nao termina em multiplo de oito nao existe, porque a tabela e
    // alinhada, e os bits baixos do dword pertencem ao BIR.
    const odd = capabilityImage(0, 0x2015, 0); // 0x2015 = 0x2010 com o BIR 5
    const other = try placement(capability, odd.reader());
    try std.testing.expectEqual(@as(u3, 5), other.table.bir);
    try std.testing.expectEqual(@as(u32, 0x2010), other.table.offset);
}

test "uma capability que nao e MSI-X nao tem tabela" {
    const image = capabilityImage(0, 0, 0);
    const wrong: pci.Capability = .{ .id = msi.capability_id, .offset = 0x40, .length = null };
    try std.testing.expectError(error.NotMsixCapability, placement(wrong, image.reader()));

    // Uma capability no fim do espaco nao tem os doze bytes que a MSI-X usa.
    const edge: pci.Capability = .{ .id = capability_id, .offset = 0xF8, .length = null };
    try std.testing.expectError(error.OutsideConfigSpace, placement(edge, image.reader()));
}

test "a tabela tem de estar num BAR de memoria que a funcao implementa" {
    var bars: BarInfo = @splat(null);
    var sizes: pci.BarSizes = @splat(null);

    const location: Location = .{ .bir = 3, .offset = 0x2000 };
    // Sem BAR: a tabela existe na capability e nao existe na funcao.
    try std.testing.expectError(error.MissingBar, validateTable(location, bars, sizes));

    // Um BAR de I/O nao e memoria, ainda que tenha tamanho.
    bars[3] = .{ .address = 0x2000, .is_io = true, .is_64bit = false, .prefetchable = false };
    sizes[3] = 0x100;
    try std.testing.expectError(error.IoBar, validateTable(location, bars, sizes));

    // Memoria, e a tabela passa do fim do BAR.
    bars[3] = .{ .address = 0x8000_0000, .is_io = false, .is_64bit = false, .prefetchable = false };
    sizes[3] = 0x1000;
    try std.testing.expectError(error.TableOutsideBar, validateTable(location, bars, sizes));

    // Memoria com uma entrada inteira a partir do offset: cabe. O teste usa o
    // tamanho minimo que a especificacao aceita para uma MSI-X (uma entrada).
    sizes[3] = 0x2000 + entry_size;
    try validateTable(location, bars, sizes);

    // Um BIR acima do numero de BARs nao nomeia nada.
    try std.testing.expectError(
        error.MissingBar,
        validateTable(.{ .bir = 5, .offset = 0 }, bars, sizes),
    );
}

test "uma entrada de 16 bytes leva endereco, superior, dado e a mascara" {
    var table: [entry_size * 2]u8 = @splat(0);

    const first = try entry(2, msi.first_device_vector);
    try std.testing.expectEqual(@as(u32, 0xFEE0_0000 | (2 << 12)), first.address);
    try std.testing.expectEqual(@as(u32, msi.first_device_vector), first.data);
    // A entrada nasce mascarada: preencher nao e liberar.
    try std.testing.expect(first.masked);

    try writeEntry(&table, 0, first);
    const read_back = readEntry(&table, 0).?;
    try std.testing.expectEqual(first, read_back);

    // A segunda entrada ficou intacta: escrever uma nao pode tocar na vizinha.
    const second = readEntry(&table, 1).?;
    try std.testing.expectEqual(@as(u32, 0), second.address);
    try std.testing.expectEqual(@as(u32, 0), second.data);

    // ... e a mascara e o unico bit do controle que muda.
    try std.testing.expect(unmask(&table, 0));
    try std.testing.expect(!readEntry(&table, 0).?.masked);
    try std.testing.expect(mask(&table, 0));
    try std.testing.expect(readEntry(&table, 0).?.masked);
}

test "um vetor do kernel nao entra na tabela de um dispositivo" {
    for ([_]u8{ 0, 8, 32, 64, 67, 0xFF }) |vector| {
        try std.testing.expectError(error.VectorBelongsToKernel, entry(1, vector));
    }
    // O primeiro livre entra, e cada entrada pode ter o proprio vetor: e a
    // razao de a tabela existir.
    const a = try entry(1, 68);
    const b = try entry(1, 69);
    try std.testing.expect(a.data != b.data);
}

test "escrever fora da janela e recusado, e os bytes existentes ficam" {
    var table: [entry_size]u8 = @splat(0);
    // A janela de uma entrada so aceita o indice 0; o 1 nao tem bytes.
    try std.testing.expectEqual(entry_size, @as(u32, @intCast(table.len)));
    const value = try entry(1, 0x50);
    try std.testing.expectError(error.TableTooShort, writeEntry(&table, 1, value));
    try std.testing.expect(!unmask(&table, 1));
    try std.testing.expect(!mask(&table, 1));

    // O que estava la continua la: uma recusa nao e uma escrita parcial.
    for (table) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a funcao fica mascarada enquanto a tabela e preenchida" {
    const declared: u16 = 31;

    // O caminho completo: a funcao comeca mascarada e desabilitada.
    var control = controlFor(declared, false, true);
    try std.testing.expect(control & Control.function_mask != 0);
    try std.testing.expect(control & Control.enable == 0);
    try std.testing.expectEqual(@as(u16, 32), tableSize(control));

    // Habilita com a funcao ainda mascarada: nada sai, e a tabela ja pode ser
    // preenchida em paz.
    control = controlFor(control, true, true);
    try std.testing.expect(control & Control.enable != 0);
    try std.testing.expect(control & Control.function_mask != 0);

    // Desmascara a funcao por ultimo: e o instante em que o dispositivo passa a
    // poder interromper, e so depois de todas as entradas existirem.
    control = controlFor(control, true, false);
    try std.testing.expect(control & Control.function_mask == 0);
    try std.testing.expect(control & Control.enable != 0);
    // O tamanho nao muda com os bits de estado.
    try std.testing.expectEqual(@as(u16, 32), tableSize(control));

    // E o bit do `Command` que desliga a INTx, para o evento nao chegar duas
    // vezes: uma pela linha e uma pela mensagem.
    try std.testing.expectEqual(@as(u16, 0x0400), command_disable_intx);
}
