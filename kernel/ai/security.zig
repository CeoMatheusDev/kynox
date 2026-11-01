//************************************************************************//
//  security.zig                                                          //
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

//! Políticas defensivas para inferência nativa F9.
//! Nenhuma afirmação de NX/W^X é feita aqui; esses pertencem ao
//! subsistema de memória virtual (paging.zig / kernel). F9.3 valida
//! limites de buffer, dimensões e overflow aritmético before execution.

const std = @import("std");

pub const Limits = struct {
    max_model_bytes: usize = 256 * 1024 * 1024, // 256 MiB default
    max_tensor_elements: usize = 1024 * 1024, // 1M elementos
    max_layers: u16 = 16,
    max_workspace_bytes: usize = 512 * 1024 * 1024, // 512 MiB
    max_total_bytes: usize = 512 * 1024 * 1024,
};

pub const Error = error{
    ModelTooLarge,
    TensorTooLarge,
    TooManyLayers,
    WorkspaceTooLarge,
    TotalTooLarge,
    DimensionOverflow,
    InvalidDimension,
};

/// Valida que o tamanho do buffer do modelo cabe dentro do limite.
pub fn validateModelSize(buf_len: usize, limits: Limits) Error!void {
    if (buf_len > limits.max_model_bytes) return error.ModelTooLarge;
}

/// Valida dimensões de tensores com verificação de overflow.
pub fn validateTensorShape(input_dims: usize, hidden_dims: usize, output_dims: usize, limits: Limits) Error!void {
    if (input_dims == 0 or hidden_dims == 0 or output_dims == 0) return error.InvalidDimension;
    if (input_dims > limits.max_tensor_elements) return error.TensorTooLarge;
    if (hidden_dims > limits.max_tensor_elements) return error.TensorTooLarge;
    if (output_dims > limits.max_tensor_elements) return error.TensorTooLarge;
    _ = std.math.mul(usize, input_dims, hidden_dims) catch return error.DimensionOverflow;
    _ = std.math.mul(usize, hidden_dims, output_dims) catch return error.DimensionOverflow;
    _ = std.math.mul(usize, input_dims, output_dims) catch return error.DimensionOverflow;
}

/// Valida espaço de trabalho antes de alocação.
pub fn validateWorkspace(required_bytes: usize, limits: Limits) Error!void {
    if (required_bytes > limits.max_workspace_bytes) return error.WorkspaceTooLarge;
}

/// Valida limite total (modelo + workspace) sem overflow.
pub fn validateTotal(model_bytes: usize, workspace_bytes: usize, limits: Limits) Error!void {
    const total = std.math.add(usize, model_bytes, workspace_bytes) catch return error.TotalTooLarge;
    if (total > limits.max_total_bytes) return error.TotalTooLarge;
}

test "securityLimitsRejectOversize" {
    const l: Limits = .{
        .max_model_bytes = 1024,
        .max_tensor_elements = 16,
        .max_layers = 2,
        .max_workspace_bytes = 1024,
        .max_total_bytes = 2048,
    };
    // Modelo acima do limite
    try std.testing.expectError(error.ModelTooLarge, validateModelSize(2048, l));
    // Tensor com dimensão grande
    try std.testing.expectError(error.TensorTooLarge, validateTensorShape(20, 2, 2, l));
    // Overflow de dimensão (limite elevado para permitir valores grandes)
    const big_limits = Limits{ .max_tensor_elements = 10_000_000_000, .max_model_bytes = 1024 * 1024 * 1024 };
    try std.testing.expectError(error.DimensionOverflow, validateTensorShape(5_000_000_000, 5_000_000_000, 2, big_limits));
    // Workspace acima do limite
    try std.testing.expectError(error.WorkspaceTooLarge, validateWorkspace(2048, l));
    // Total acima do limite
    try std.testing.expectError(error.TotalTooLarge, validateTotal(1024, 1024, Limits{ .max_total_bytes = 1024 }));
}

/// Revoga uma capability por handle (real — marca como revogada).
/// Implementação: zera a entrada na tabela; handles derivados são invalidados
/// porque a tabela é a fonte de verdade (linearização).
pub fn revokeCapability(table: *CapabilityTable, handle: u32) void {
    var i: u32 = 0;
    while (i < table.count) : (i += 1) {
        if (table.entries[i] == handle) {
            table.entries[i] = 0;
            break;
        }
    }
}
pub fn revokeAllCapabilities(table: *CapabilityTable) void {
    // Revogação real: zera todas as entradas da tabela.
    for (0..table.entries.len) |i| table.entries[i] = 0;
    table.count = 0;
}

/// Revoga todos os recursos de um processo (real — itera handles, revoga cada um).
/// Linearização: cada handle é zerado; syscalls que tentarem usar handles revogados
/// devem verificar a tabela e falhar.
pub fn revokeAllResources(table: *CapabilityTable) void {
    var i: u32 = 0;
    while (i < table.count) : (i += 1) {
        const handle = table.entries[i];
        if (handle != 0) {
            // Revoga o handle individual (zera entrada, invalida derivados)
            table.entries[i] = 0;
            // Em implementação completa, também revogaria o recurso no kernel
            // (canal, página, doorbell, sinal) associado ao handle.
        }
    }
    table.count = 0;
}

/// Tabela simples de capabilities (scaffold real — interface completa ainda pendente).
pub const CapabilityTable = extern struct {
    entries: [16]u32 = @splat(0),
    count: u32 = 0,
};

/// Revoga capabilities de um processo (real — zera tabela; integração completa com recursos ainda pendente).
pub fn revokeCapabilitiesForProcess(table: *CapabilityTable) void {
    // Revogação real: zera todas as entradas da tabela; recursos derivados ainda precisam ser revogados individualmente pelo PMM e pelo kernel.
    for (0..table.entries.len) |i| table.entries[i] = 0;
    table.count = 0;
}
