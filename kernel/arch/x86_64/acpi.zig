//************************************************************************//
//  acpi.zig                                                              //
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

//! Descoberta de processadores pela ACPI.
//!
//! O carregador entrega o endereco fisico do RSDP (Root System Description
//! Pointer) no handoff. Durante o boot, antes de o kernel trocar as tabelas
//! de paginas do firmware, a memoria apontada pelo RSDP ainda esta acessivel
//! por identidade. O kernel le o RSDP, percorre a XSDT (ou a RSDT, em
//! sistemas ACPI 1.0) e localiza a MADT (Multiple APIC Description Table),
//! que descreve o APIC local de cada processador.
//!
//! As funcoes de validacao recebem fatias de bytes para que possam ser
//! testadas no host com tabelas sinteticas; a leitura da memoria fisica fica
//! na funcao de descoberta do modulo de SMP.
//!
//! Referencias: ACPI Specification 6.5, secoes 5.2.5 (RSDP), 5.2.7 (XSDT),
//! 5.2.6 (RSDT) e 5.2.12 (MADT).

const std = @import("std");

/// Assinatura do RSDP.
pub const rsdp_signature = "RSD PTR ";

/// Assinatura da RSDT.
pub const rsdt_signature = "RSDT";

/// Assinatura da XSDT.
pub const xsdt_signature = "XSDT";

/// Assinatura da MADT.
pub const madt_signature = "APIC";

/// Tamanho minimo do RSDP (ACPI 1.0).
pub const rsdp_base_size = 20;

/// Tamanho do RSDP estendido (ACPI 2.0 em diante).
pub const rsdp_extended_size = 36;

/// Tamanho minimo do cabecalho da MADT.
pub const madt_header_size = 44;

/// Maior tabela ACPI que o kernel aceita, em bytes.
///
/// O limite existe para que um ponteiro corrompido nao faca o kernel ler
/// uma regiao arbitraria da memoria: as tabelas reais tem alguns kibibytes.
pub const max_table_size = 1024 * 1024;

/// Tamanho de uma pagina, usado para validar os enderecos das APICs.
pub const page_size: u64 = 4096;

/// Limite do mapeamento identidade do firmware, em bytes.
///
/// Um endereco de APIC acima deste limite nao pode ser usado com o mapa de
/// paginas atual; o descobridor devolve `null` e o kernel cai no fallback.
pub const identity_mapped_limit: u64 = 4 * 1024 * 1024 * 1024;

/// Numero maximo de IOAPICs registrados pela descoberta.
pub const max_io_apics = 4;

/// Numero maximo de overrides de origem de interrupcao registrados.
pub const max_isa_overrides = 8;

/// Erros da validacao e da leitura das tabelas.
pub const Error = error{
    /// A assinatura da tabela nao e a esperada.
    InvalidSignature,
    /// A soma de verificacao nao fecha.
    InvalidChecksum,
    /// A tabela e menor do que o cabecalho que ela declara.
    TruncatedTable,
    /// O comprimento declarado excede o limite ou a fatia recebida.
    InvalidLength,
    /// A versao do RSDP nao e suportada.
    UnsupportedRevision,
    /// A fonte de tabelas nao entregou a fatia pedida.
    UnreadableTable,
    /// O RSDP nao descreve nenhuma tabela MADT.
    NoMadt,
    /// A tabela de primeiro nivel nao e a XSDT esperada.
    UnexpectedContainer,
};

/// Conteudo do RSDP que a descoberta usa.
pub const Rsdp = struct {
    /// Versao da ACPI reportada pelo firmware.
    revision: u8,
    /// Endereco fisico da RSDT (ACPI 1.0), zero quando ausente.
    rsdt_address: u32,
    /// Endereco fisico da XSDT (ACPI 2.0 em diante), zero quando ausente.
    xsdt_address: u64,
};

/// Descreve um processador encontrado na MADT.
pub const Processor = struct {
    /// Identificador do APIC local do processador.
    apic_id: u32 = 0,
    /// O firmware reporta o processador como habilitado.
    enabled: bool = false,
    /// A entrada e do tipo x2APIC (identificador de 32 bits).
    x2apic: bool = false,
};

/// Um IOAPIC descrito pela MADT.
pub const IoApic = struct {
    /// Identificador do IOAPIC na tabela.
    id: u8 = 0,
    /// Endereco fisico do bloco de registradores.
    address: u32 = 0,
    /// Primeira linha de interrupcao global (GSI) atendida.
    gsi_base: u32 = 0,

    /// Um endereco utilizavel: nao nulo, alinhado a pagina e abaixo do
    /// limite do mapeamento identidade.
    pub fn isValid(self: IoApic) bool {
        if (self.address == 0) return false;
        if (self.address % page_size != 0) return false;
        return self.address < identity_mapped_limit;
    }
};

/// Override de origem de interrupcao descrito pela MADT.
///
/// Mapeia uma linha do barramento ISA (IRQ) para uma GSI e carrega as flags
/// de polaridade/trigger; o kernel ainda nao programa o IOAPIC, mas a
/// informacao fica registrada para o incremento que o fizer.
pub const IsaOverride = struct {
    /// Barramento da origem (0 = ISA).
    bus: u8 = 0,
    /// Linha de interrupcao de origem.
    source: u8 = 0,
    /// Linha de interrupcao global de destino.
    gsi: u32 = 0,
    /// Flags de polaridade e de disparo (MPS INTI).
    flags: u16 = 0,
};

/// Resultado da leitura da MADT.
pub const Madt = struct {
    /// Endereco fisico do APIC local, lido da tabela.
    local_apic_base: u64 = 0,
    /// Numero de processadores gravados em `processors`.
    count: usize = 0,
    /// A tabela descreve mais processadores do que a capacidade da fatia.
    truncated: bool = false,
    /// IOAPICs gravados pela leitura.
    io_apics: [max_io_apics]IoApic = @splat(.{}),
    /// Numero de IOAPICs gravados.
    io_apic_count: u8 = 0,
    /// A tabela descreve mais IOAPICs do que a capacidade da fatia.
    io_apic_overflow: bool = false,
    /// Overrides de origem gravados pela leitura.
    overrides: [max_isa_overrides]IsaOverride = @splat(.{}),
    /// Numero de overrides gravados.
    override_count: u8 = 0,
    /// A tabela descreve mais overrides do que a capacidade da fatia.
    override_overflow: bool = false,

    /// Endereco do APIC local, validado para uso direto.
    ///
    /// Devolve `null` quando a tabela nao traz um endereco utilizavel: zero,
    /// desalinhado ou fora do mapeamento identidade. O chamador cai no
    /// endereco padrao documentado por `apic.zig`.
    pub fn lapicBase(self: Madt) ?u64 {
        if (self.local_apic_base == 0) return null;
        if (self.local_apic_base % page_size != 0) return null;
        if (self.local_apic_base >= identity_mapped_limit) return null;
        return self.local_apic_base;
    }
};

/// Le um inteiro de 32 bits little-endian de uma fatia.
fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

/// Le um inteiro de 16 bits little-endian de uma fatia.
fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

/// Le um inteiro de 64 bits little-endian de uma fatia.
fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

/// Soma todos os bytes de uma fatia com aritmetica de 8 bits.
///
/// As tabelas ACPI sao validadas por uma soma que deve resultar em zero.
pub fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum;
}

/// Valida a parte comum (ACPI 1.0) do RSDP.
///
/// A fatia tem de ter pelo menos 20 bytes. A soma de verificacao cobre
/// exatamente os primeiros 20 bytes nas duas versoes do formato.
pub fn validateRsdpBase(bytes: []const u8) Error!Rsdp {
    if (bytes.len < rsdp_base_size) return error.TruncatedTable;
    if (!std.mem.eql(u8, bytes[0..8], rsdp_signature)) return error.InvalidSignature;
    if (checksum(bytes[0..rsdp_base_size]) != 0) return error.InvalidChecksum;

    const revision = bytes[15];
    if (revision > 2) return error.UnsupportedRevision;

    return .{
        .revision = revision,
        .rsdt_address = readU32(bytes, 16),
        .xsdt_address = 0,
    };
}

/// Valida a parte estendida do RSDP e devolve o endereco da XSDT.
///
/// A fatia tem de ter pelo menos 36 bytes. A soma estendida cobre a
/// estrutura inteira e so existe a partir da revisao 2.
pub fn validateRsdpExtended(bytes: []const u8) Error!u64 {
    if (bytes.len < rsdp_extended_size) return error.TruncatedTable;
    if (checksum(bytes[0..rsdp_extended_size]) != 0) return error.InvalidChecksum;
    return readU64(bytes, 24);
}

/// Le o comprimento declarado no cabecalho de uma tabela ACPI.
///
/// O cabecalho tem 36 bytes; a funcao so confere os limites do valor, sem
/// exigir que a fatia contenha a tabela inteira. E a forma usada quando o
/// kernel le apenas o cabecalho e depois monta a fatia da tabela.
pub fn declaredLength(bytes: []const u8) Error!usize {
    if (bytes.len < 8) return error.TruncatedTable;
    const length = readU32(bytes, 4);
    if (length < 36 or length > max_table_size) return error.InvalidLength;
    return length;
}

/// Le o comprimento de uma tabela ACPI e verifica os limites.
///
/// O cabecalho tem 36 bytes: assinatura de 4 bytes, comprimento de 4 bytes,
/// revisao, soma de verificacao, identificador do fornecedor, identificador
/// da tabela e numero da revisao do fornecedor.
pub fn tableLength(bytes: []const u8) Error!usize {
    if (bytes.len < 36) return error.TruncatedTable;
    const length = try declaredLength(bytes);
    if (length > bytes.len) return error.InvalidLength;
    return length;
}

/// Confere a assinatura de uma tabela.
pub fn hasSignature(bytes: []const u8, signature: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.eql(u8, bytes[0..4], signature);
}

/// Le a MADT e grava os processadores habilitados na fatia recebida.
///
/// A fatia `processors` limita quantos processadores o kernel registra.
/// Entradas desabilitadas pelo firmware sao ignoradas; quando existem mais
/// processadores habilitados do que a capacidade da fatia, `truncated` fica
/// verdadeiro e o excedente nao e gravado.
pub fn parseMadt(bytes: []const u8, processors: []Processor) Error!Madt {
    if (!hasSignature(bytes, madt_signature)) return error.InvalidSignature;

    const length = try tableLength(bytes);
    if (length < madt_header_size) return error.TruncatedTable;
    if (checksum(bytes[0..length]) != 0) return error.InvalidChecksum;

    var result = Madt{
        .local_apic_base = readU32(bytes, 36),
    };

    var offset: usize = madt_header_size;
    while (offset + 2 <= length) {
        const entry_type = bytes[offset];
        const entry_length = bytes[offset + 1];
        if (entry_length < 2) return error.InvalidLength;
        if (offset + entry_length > length) return error.InvalidLength;

        switch (entry_type) {
            // Processor Local APIC (ACPI 1.0).
            0 => {
                if (entry_length < 8) return error.InvalidLength;
                const flags = readU32(bytes, offset + 4);
                if (flags & 1 != 0) {
                    if (result.count < processors.len) {
                        processors[result.count] = .{
                            .apic_id = bytes[offset + 3],
                            .enabled = true,
                            .x2apic = false,
                        };
                        result.count += 1;
                    } else {
                        result.truncated = true;
                    }
                }
            },
            // Processor Local x2APIC.
            9 => {
                if (entry_length < 16) return error.InvalidLength;
                const flags = readU32(bytes, offset + 8);
                if (flags & 1 != 0) {
                    if (result.count < processors.len) {
                        processors[result.count] = .{
                            .apic_id = readU32(bytes, offset + 4),
                            .enabled = true,
                            .x2apic = true,
                        };
                        result.count += 1;
                    } else {
                        result.truncated = true;
                    }
                }
            },
            // I/O APIC.
            1 => {
                if (entry_length < 12) return error.InvalidLength;
                if (result.io_apic_count < max_io_apics) {
                    result.io_apics[result.io_apic_count] = .{
                        .id = bytes[offset + 2],
                        .address = readU32(bytes, offset + 4),
                        .gsi_base = readU32(bytes, offset + 8),
                    };
                    result.io_apic_count += 1;
                } else {
                    result.io_apic_overflow = true;
                }
            },
            // Interrupt Source Override.
            2 => {
                if (entry_length < 10) return error.InvalidLength;
                if (result.override_count < max_isa_overrides) {
                    result.overrides[result.override_count] = .{
                        .bus = bytes[offset + 2],
                        .source = bytes[offset + 3],
                        .gsi = readU32(bytes, offset + 4),
                        .flags = readU16(bytes, offset + 8),
                    };
                    result.override_count += 1;
                } else {
                    result.override_overflow = true;
                }
            },
            // Local APIC Address Override.
            5 => {
                if (entry_length < 12) return error.InvalidLength;
                result.local_apic_base = readU64(bytes, offset + 4);
            },
            else => {},
        }

        offset += entry_length;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Rotas de interrupcao
// ---------------------------------------------------------------------------

/// Rota efetiva de uma linha de interrupcao ISA.
///
/// O valor e calculado a partir dos overrides da MADT: a linha `irq` pode ser
/// redirecionada para outra GSI e pode inverter polaridade ou mudar de
/// disparo. Sem override, a rota e a identidade e a convencao da ISA
/// (ativo em nivel alto, disparo por borda).
pub const IsaRoute = struct {
    /// GSI que entrega a linha.
    gsi: u32 = 0,
    /// Polaridade: 0 = ativo em nivel alto, 1 = ativo em nivel baixo.
    polarity: u1 = 0,
    /// Disparo: 0 = borda, 1 = nivel.
    trigger: u1 = 0,
    /// A rota veio de um interrupt source override.
    overridden: bool = false,
};

/// Barramento ISA no campo `bus` de um override da MADT.
pub const isa_bus: u8 = 0;

/// Resolve a rota de uma linha ISA.
///
/// A primeira entrada com o mesmo barramento e a mesma origem vence; a busca
/// e linear porque a tabela e pequena e imutavel depois do boot. Valores
/// reservados nas flags (3) sao tratados como "conforme o barramento", que e
/// o comportamento que a ACPI define para eles.
pub fn isaRoute(irq: u8, overrides: []const IsaOverride) IsaRoute {
    var route: IsaRoute = .{ .gsi = irq };
    for (overrides) |override| {
        if (override.bus != isa_bus) continue;
        if (override.source != irq) continue;

        route.gsi = override.gsi;
        route.overridden = true;
        route.polarity = switch (override.flags & 0b11) {
            2 => 1, // ativo em nivel baixo
            else => 0, // conforme o barramento (ativo em nivel alto)
        };
        route.trigger = switch ((override.flags >> 2) & 0b11) {
            2 => 1, // nivel
            else => 0, // conforme o barramento (borda)
        };
        return route;
    }
    return route;
}

// ---------------------------------------------------------------------------
// Descoberta a partir do RSDP
// ---------------------------------------------------------------------------

/// Fonte de tabelas ACPI no espaco de enderecos do chamador.
///
/// A leitura e injetada para que a descoberta seja testavel no host: o
/// kernel entrega uma funcao que le a memoria fisica atraves do mapeamento
/// identidade do firmware, e os testes entregam um buffer.
pub const TableSource = struct {
    context: *anyopaque,
    /// Devolve exatamente `length` bytes em `address`, ou null quando a
    /// fonte nao consegue (endereco invalido, fora do limite, truncado).
    read: *const fn (context: *anyopaque, address: u64, length: usize) ?[]const u8,
};

/// Resultado da descoberta: a MADT e o endereco de onde ela veio.
pub const Discovered = struct {
    /// Endereco fisico da MADT encontrada.
    madt_address: u64,
    /// Conteudo interpretado da MADT.
    madt: Madt,
};

/// Le uma tabela inteira a partir do endereco, validando assinatura,
/// comprimento e soma de verificacao.
///
/// A leitura acontece em duas etapas porque o comprimento esta no cabecalho:
/// primeiro os 36 bytes do cabecalho, depois a tabela inteira.
fn readTable(source: TableSource, address: u64) Error![]const u8 {
    if (address == 0) return error.UnreadableTable;
    const header = source.read(source.context, address, 36) orelse return error.UnreadableTable;
    const length = try declaredLength(header);
    const table = source.read(source.context, address, length) orelse return error.UnreadableTable;
    if (table.len != length) return error.UnreadableTable;
    if (checksum(table) != 0) return error.InvalidChecksum;
    return table;
}

/// Procura a tabela `signature` nas entradas de uma tabela de primeiro nivel
/// (XSDT ou RSDT) ja validada.
fn findEntry(
    source: TableSource,
    container: []const u8,
    signature: []const u8,
    entry_size: usize,
) Error!?u64 {
    var offset: usize = 36;
    while (offset + entry_size <= container.len) : (offset += entry_size) {
        const address: u64 = if (entry_size == 8)
            readU64(container, offset)
        else
            @as(u64, readU32(container, offset));
        if (address == 0) continue;

        // Uma entrada que nao pode ser lida nao invalida a busca: o firmware
        // pode publicar entradas reservadas. Ela e apenas ignorada.
        const table = readTable(source, address) catch continue;
        if (hasSignature(table, signature)) return address;
    }
    return null;
}

/// Localiza a MADT a partir do RSDP e a interpreta.
///
/// Aceita ACPI 2.0 em diante (XSDT) e ACPI 1.0 (RSDT). Erros de leitura,
/// assinatura, comprimento ou soma de verificacao sao propagados para que o
/// kernel registre o motivo e caia no fallback; ausencia de MADT e
/// `error.NoMadt`.
pub fn discoverMadt(
    source: TableSource,
    rsdp_address: u64,
    processors: []Processor,
) Error!Discovered {
    const rsdp_bytes = source.read(source.context, rsdp_address, rsdp_extended_size) orelse
        source.read(source.context, rsdp_address, rsdp_base_size) orelse
        return error.UnreadableTable;

    const rsdp = try validateRsdpBase(rsdp_bytes);

    var container_address: u64 = 0;
    var entry_size: usize = 4;
    var container_signature: []const u8 = rsdt_signature;

    if (rsdp.revision >= 2 and rsdp_bytes.len >= rsdp_extended_size) {
        const xsdt_address = try validateRsdpExtended(rsdp_bytes);
        if (xsdt_address != 0) {
            container_address = xsdt_address;
            entry_size = 8;
            container_signature = xsdt_signature;
        }
    }
    if (container_address == 0) {
        if (rsdp.rsdt_address == 0) return error.UnexpectedContainer;
        container_address = @as(u64, rsdp.rsdt_address);
    }

    const container = try readTable(source, container_address);
    if (!hasSignature(container, container_signature)) return error.UnexpectedContainer;

    const madt_address = (try findEntry(source, container, madt_signature, entry_size)) orelse
        return error.NoMadt;

    const madt_bytes = try readTable(source, madt_address);
    const madt = try parseMadt(madt_bytes, processors);
    return .{ .madt_address = madt_address, .madt = madt };
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

/// Preenche uma tabela sintetica com a soma de verificacao correta.
fn seal(table: []u8) void {
    table[9] = 0;
    table[9] = 0 -% checksum(table);
}

test "checksum closes a sealed table" {
    var table = [_]u8{ 1, 2, 3, 4 };
    table[3] = 0 -% checksum(table[0..3]);
    try std.testing.expectEqual(@as(u8, 0), checksum(&table));
}

test "validateRsdpBase accepts a valid ACPI 1.0 RSDP" {
    var rsdp: [rsdp_base_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], rsdp_signature);
    rsdp[15] = 0;
    std.mem.writeInt(u32, rsdp[16..20], 0x1000, .little);
    rsdp[8] = 0 -% checksum(rsdp[0..20]);

    const parsed = try validateRsdpBase(&rsdp);
    try std.testing.expectEqual(@as(u8, 0), parsed.revision);
    try std.testing.expectEqual(@as(u32, 0x1000), parsed.rsdt_address);
    try std.testing.expectEqual(@as(u64, 0), parsed.xsdt_address);
}

test "validateRsdpBase rejects a bad signature" {
    var rsdp: [rsdp_base_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], "BAD PTR ");
    rsdp[8] = 0 -% checksum(rsdp[0..20]);
    try std.testing.expectError(error.InvalidSignature, validateRsdpBase(&rsdp));
}

test "validateRsdpBase rejects a bad checksum" {
    var rsdp: [rsdp_base_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], rsdp_signature);
    rsdp[8] = 1;
    try std.testing.expectError(error.InvalidChecksum, validateRsdpBase(&rsdp));
}

test "validateRsdpExtended reads the XSDT address" {
    var rsdp: [rsdp_extended_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], rsdp_signature);
    rsdp[15] = 2;
    std.mem.writeInt(u64, rsdp[24..32], 0x2000_0000, .little);
    rsdp[8] = 0 -% checksum(rsdp[0..36]);

    try std.testing.expectEqual(@as(u64, 0x2000_0000), try validateRsdpExtended(&rsdp));
}

test "tableLength rejects a table larger than the buffer" {
    var header: [36]u8 = @splat(0);
    std.mem.writeInt(u32, header[4..8], 4096, .little);
    try std.testing.expectError(error.InvalidLength, tableLength(&header));
}

/// Monta um cabecalho de tabela ACPI sintetico.
fn makeHeader(destination: []u8, signature: []const u8, length: usize) void {
    @memset(destination, 0);
    @memcpy(destination[0..4], signature);
    std.mem.writeInt(u32, destination[4..8], @intCast(length), .little);
}

test "parseMadt reads the local APIC base and the processors" {
    var table: [64]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);

    // Processor Local APIC: tipo 0, comprimento 8, id 0, flags 1.
    table[44] = 0;
    table[45] = 8;
    table[46] = 0;
    table[47] = 0;
    std.mem.writeInt(u32, table[48..52], 1, .little);

    // Segundo processador, desabilitado (flags 0).
    table[52] = 0;
    table[53] = 8;
    table[54] = 1;
    table[55] = 1;
    std.mem.writeInt(u32, table[56..60], 0, .little);

    // Terceiro processador, habilitado, id 2.
    table[60] = 0;
    table[61] = 4; // comprimento menor que o minimo: a tabela sera recusada
    seal(&table);

    try std.testing.expectError(error.InvalidLength, parseMadt(&table, &[_]Processor{}));
}

test "parseMadt accepts two enabled processors" {
    var table: [72]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);

    // Primeiro processador habilitado.
    table[44] = 0;
    table[45] = 8;
    table[46] = 0;
    table[47] = 0;
    std.mem.writeInt(u32, table[48..52], 1, .little);

    // Segundo processador habilitado.
    table[52] = 0;
    table[53] = 8;
    table[54] = 0;
    table[55] = 1;
    std.mem.writeInt(u32, table[56..60], 1, .little);

    // Entrada de sobreposicao do endereco do APIC local.
    table[60] = 5;
    table[61] = 12;
    std.mem.writeInt(u64, table[64..72], 0xFEE0_1000, .little);

    seal(&table);

    var processors: [4]Processor = @splat(.{});
    const result = try parseMadt(&table, &processors);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(u32, 0), processors[0].apic_id);
    try std.testing.expectEqual(@as(u32, 1), processors[1].apic_id);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqual(@as(u64, 0xFEE0_1000), result.local_apic_base);
}

test "parseMadt reports truncation when the slice is too small" {
    var table: [52]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);
    table[44] = 0;
    table[45] = 8;
    table[46] = 0;
    table[47] = 0;
    std.mem.writeInt(u32, table[48..52], 1, .little);
    seal(&table);

    var processors: [0]Processor = .{};
    const result = try parseMadt(&table, &processors);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expect(result.truncated);
}

test "parseMadt records the IOAPICs and the source overrides" {
    var table: [86]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);

    // Processor Local APIC (tipo 0, comprimento 8).
    table[44] = 0;
    table[45] = 8;
    table[46] = 0;
    table[47] = 0;
    std.mem.writeInt(u32, table[48..52], 1, .little);

    // I/O APIC (tipo 1, comprimento 12): id 2, endereco 0xFEC00000, GSI 0.
    table[52] = 1;
    table[53] = 12;
    table[54] = 2;
    std.mem.writeInt(u32, table[56..60], 0xFEC0_0000, .little);
    std.mem.writeInt(u32, table[60..64], 0, .little);

    // Interrupt Source Override (tipo 2, comprimento 10): ISA IRQ 0 -> GSI 2.
    table[64] = 2;
    table[65] = 10;
    table[66] = 0; // barramento ISA
    table[67] = 0; // IRQ 0
    std.mem.writeInt(u32, table[68..72], 2, .little);
    std.mem.writeInt(u16, table[72..74], 0, .little);

    // Um segundo IOAPIC, fora de qualquer expectativa de hardware: o parser
    // registra o que a tabela diz, a validacao de uso fica em `isValid`.
    table[74] = 1;
    table[75] = 12;
    table[76] = 3;
    std.mem.writeInt(u32, table[78..82], 0xFEC0_1000, .little);
    std.mem.writeInt(u32, table[82..86], 24, .little);

    seal(&table);

    var processors: [4]Processor = @splat(.{});
    const result = try parseMadt(&table, &processors);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(u8, 2), result.io_apic_count);
    try std.testing.expectEqual(@as(u8, 2), result.io_apics[0].id);
    try std.testing.expectEqual(@as(u32, 0xFEC0_0000), result.io_apics[0].address);
    try std.testing.expectEqual(@as(u32, 24), result.io_apics[1].gsi_base);
    try std.testing.expect(result.io_apics[0].isValid());
    try std.testing.expect(result.io_apics[1].isValid());
    try std.testing.expectEqual(@as(u8, 1), result.override_count);
    try std.testing.expectEqual(@as(u8, 0), result.overrides[0].source);
    try std.testing.expectEqual(@as(u32, 2), result.overrides[0].gsi);
    try std.testing.expect(!result.io_apic_overflow);
    try std.testing.expect(!result.override_overflow);
}

test "parseMadt rejects an IOAPIC entry that is too short" {
    var table: [56]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);
    table[44] = 1; // I/O APIC
    table[45] = 8; // comprimento invalido (o minimo e 12)
    seal(&table);

    var processors: [1]Processor = @splat(.{});
    try std.testing.expectError(error.InvalidLength, parseMadt(&table, &processors));
}

test "the IOAPIC address validation rejects unusable values" {
    const good: IoApic = .{ .id = 1, .address = 0xFEC0_0000, .gsi_base = 0 };
    try std.testing.expect(good.isValid());

    const null_address: IoApic = .{ .id = 1, .address = 0, .gsi_base = 0 };
    try std.testing.expect(!null_address.isValid());

    const misaligned: IoApic = .{ .id = 1, .address = 0xFEC0_0004, .gsi_base = 0 };
    try std.testing.expect(!misaligned.isValid());
}

test "the discovered LAPIC base is validated before use" {
    const good: Madt = .{ .local_apic_base = 0xFEE0_0000 };
    try std.testing.expectEqual(@as(?u64, 0xFEE0_0000), good.lapicBase());

    const absent: Madt = .{ .local_apic_base = 0 };
    try std.testing.expectEqual(@as(?u64, null), absent.lapicBase());

    const misaligned: Madt = .{ .local_apic_base = 0xFEE0_0800 };
    try std.testing.expectEqual(@as(?u64, null), misaligned.lapicBase());

    const beyond: Madt = .{ .local_apic_base = identity_mapped_limit };
    try std.testing.expectEqual(@as(?u64, null), beyond.lapicBase());
}

// ---------------------------------------------------------------------------
// Descoberta com fonte de tabelas sintetica
// ---------------------------------------------------------------------------

/// Imagem de memoria dos testes: RSDP em 0x1000, XSDT em 0x2000, MADT em 0x3000.
const FakeMemory = struct {
    bytes: [0x4000]u8 = @splat(0),

    fn read(context: *anyopaque, address: u64, length: usize) ?[]const u8 {
        const self: *FakeMemory = @ptrCast(@alignCast(context));
        if (address % 16 != 0) return null;
        const start: usize = @intCast(address);
        const end = start + length;
        if (end > self.bytes.len) return null;
        return self.bytes[start..end];
    }

    fn source(self: *FakeMemory) TableSource {
        return .{ .context = self, .read = read };
    }

    /// Preenche RSDP (versao 2), XSDT com uma entrada e uma MADT completa.
    fn build(self: *FakeMemory, lapic_base: u64) void {
        // RSDP estendido em 0x1000. O formato tem duas somas: a de 20 bytes
        // (ACPI 1.0) e a de 36 bytes (ACPI 2.0); ambas tem de fechar em zero.
        const rsdp = self.bytes[0x1000..0x1024];
        @memcpy(rsdp[0..8], rsdp_signature);
        rsdp[15] = 2;
        std.mem.writeInt(u32, rsdp[16..20], 0x2000, .little);
        std.mem.writeInt(u64, rsdp[24..32], 0x2000, .little);
        rsdp[8] = 0 -% checksum(rsdp[0..rsdp_base_size]);
        rsdp[32] = 0 -% checksum(rsdp);

        // XSDT em 0x2000, com uma entrada apontando para a MADT.
        const xsdt = self.bytes[0x2000..0x2040];
        makeHeader(xsdt, xsdt_signature, xsdt.len);
        std.mem.writeInt(u64, xsdt[36..44], 0x3000, .little);
        seal(xsdt);

        // MADT em 0x3000, com 72 bytes: cabecalho, dois LAPICs e um IOAPIC.
        const madt = self.bytes[0x3000..0x3048];
        makeHeader(madt, madt_signature, madt.len);
        std.mem.writeInt(u32, madt[36..40], @intCast(lapic_base & 0xFFFF_FFFF), .little);

        // Dois processadores habilitados.
        madt[44] = 0;
        madt[45] = 8;
        madt[46] = 0;
        std.mem.writeInt(u32, madt[48..52], 1, .little);
        madt[52] = 0;
        madt[53] = 8;
        madt[54] = 1;
        std.mem.writeInt(u32, madt[56..60], 1, .little);

        // Um IOAPIC.
        madt[60] = 1;
        madt[61] = 12;
        madt[62] = 2;
        std.mem.writeInt(u32, madt[64..68], 0xFEC0_0000, .little);
        std.mem.writeInt(u32, madt[68..72], 0, .little);

        seal(madt);
    }
};

test "the discovery finds the MADT through the XSDT" {
    var memory: FakeMemory = .{};
    memory.build(0xFEE0_0000);

    var processors: [4]Processor = @splat(.{});
    const found = try discoverMadt(memory.source(), 0x1000, &processors);

    try std.testing.expectEqual(@as(u64, 0x3000), found.madt_address);
    try std.testing.expectEqual(@as(?u64, 0xFEE0_0000), found.madt.lapicBase());
    try std.testing.expectEqual(@as(usize, 2), found.madt.count);
    try std.testing.expectEqual(@as(u8, 1), found.madt.io_apic_count);
    try std.testing.expectEqual(@as(u32, 0xFEC0_0000), found.madt.io_apics[0].address);
}

test "the discovery falls back to the RSDT on ACPI 1.0" {
    var memory: FakeMemory = .{};
    memory.build(0xFEE0_0000);

    // RSDP de versao 0, apontando para a RSDT em 0x2000.
    const rsdp = memory.bytes[0x1000..0x1014];
    @memset(rsdp, 0);
    @memcpy(rsdp[0..8], rsdp_signature);
    rsdp[15] = 0;
    std.mem.writeInt(u32, rsdp[16..20], 0x2000, .little);
    rsdp[8] = 0 -% checksum(rsdp);

    // A RSDT usa entradas de 4 bytes.
    const table = memory.bytes[0x2000..0x2040];
    makeHeader(table, rsdt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0x3000, .little);
    seal(table);

    var processors: [4]Processor = @splat(.{});
    const found = try discoverMadt(memory.source(), 0x1000, &processors);
    try std.testing.expectEqual(@as(u64, 0x3000), found.madt_address);
    try std.testing.expectEqual(@as(usize, 2), found.madt.count);
}

test "the discovery rejects a corrupted XSDT checksum" {
    var memory: FakeMemory = .{};
    memory.build(0xFEE0_0000);
    memory.bytes[0x2009] +%= 1; // estraga a soma da XSDT

    var processors: [4]Processor = @splat(.{});
    try std.testing.expectError(
        error.InvalidChecksum,
        discoverMadt(memory.source(), 0x1000, &processors),
    );
}

test "the discovery reports a missing MADT instead of guessing" {
    var memory: FakeMemory = .{};
    memory.build(0xFEE0_0000);
    // Muda a assinatura da MADT: a entrada da XSDT deixa de casar.
    @memcpy(memory.bytes[0x3000..0x3004], "XXXX");
    seal(memory.bytes[0x3000..0x3048]);

    var processors: [4]Processor = @splat(.{});
    try std.testing.expectError(
        error.NoMadt,
        discoverMadt(memory.source(), 0x1000, &processors),
    );
}

test "the discovery rejects an unreadable RSDP" {
    var memory: FakeMemory = .{};
    memory.build(0xFEE0_0000);

    var processors: [4]Processor = @splat(.{});
    // O limite da fonte e 0x4000: um RSDP proximo ao fim nao cabe.
    try std.testing.expectError(
        error.UnreadableTable,
        discoverMadt(memory.source(), 0x3FF0, &processors),
    );
}

test "an ISA line without an override keeps its number and the ISA convention" {
    const route = isaRoute(1, &.{});
    try std.testing.expectEqual(@as(u32, 1), route.gsi);
    try std.testing.expectEqual(@as(u1, 0), route.polarity);
    try std.testing.expectEqual(@as(u1, 0), route.trigger);
    try std.testing.expect(!route.overridden);
}

test "an override moves the ISA line to another GSI" {
    // QEMU/q35 publishes the classic 8259 compatibility table: IRQ0 -> GSI2.
    const overrides = [_]IsaOverride{
        .{ .bus = 0, .source = 0, .gsi = 2, .flags = 0 },
        .{ .bus = 0, .source = 1, .gsi = 1, .flags = 0 },
    };
    const timer_route = isaRoute(0, &overrides);
    try std.testing.expectEqual(@as(u32, 2), timer_route.gsi);
    try std.testing.expect(timer_route.overridden);
    try std.testing.expectEqual(@as(u32, 1), isaRoute(1, &overrides).gsi);
    // A line that has no entry keeps the identity mapping.
    try std.testing.expectEqual(@as(u32, 4), isaRoute(4, &overrides).gsi);
}

test "an override carries polarity and trigger" {
    // Bits [1:0] = 2: active low. Bits [3:2] = 2: level triggered.
    const active_low_level = [_]IsaOverride{
        .{ .bus = 0, .source = 9, .gsi = 23, .flags = 0b1010 },
    };
    const route = isaRoute(9, &active_low_level);
    try std.testing.expectEqual(@as(u32, 23), route.gsi);
    try std.testing.expectEqual(@as(u1, 1), route.polarity);
    try std.testing.expectEqual(@as(u1, 1), route.trigger);

    // Reserved values (3 in both fields) mean "conforming": the ISA default
    // of active high and edge triggered, not a random interpretation.
    const reserved = [_]IsaOverride{
        .{ .bus = 0, .source = 5, .gsi = 5, .flags = 0b1111 },
    };
    const conforming = isaRoute(5, &reserved);
    try std.testing.expectEqual(@as(u1, 0), conforming.polarity);
    try std.testing.expectEqual(@as(u1, 0), conforming.trigger);
}

test "an override for another bus is ignored" {
    const overrides = [_]IsaOverride{
        .{ .bus = 2, .source = 1, .gsi = 9, .flags = 0 },
    };
    const route = isaRoute(1, &overrides);
    try std.testing.expectEqual(@as(u32, 1), route.gsi);
    try std.testing.expect(!route.overridden);
}
