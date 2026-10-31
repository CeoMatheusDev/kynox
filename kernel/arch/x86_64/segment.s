/**************************************************************************/
/*  segment.s                                                             */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               Kynox                                  */
/*              https://github.com/CeoMatheusDev/Kynox                  */
/**************************************************************************/
/* Copyright (C) 2026 Kynox contributors.                               */
/* Copyright (C) 2020 - 2026 Matheus.A.Santos contributors. */
/* Copyright (C) 2026 Kynox - All Rights Reserved. */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

/*
 * Access to the structures of the segment subsystem: the global descriptor
 * table and the task state segment.
 *
 * The instructions that manipulate these structures have no form that the
 * inline assembly of Zig can express with the correct operand size, and
 * their semantics depend on the exact width of the operand. They are
 * therefore implemented here, where the size is explicit.
 *
 * ABI of `kynox_gdt_load_data`:
 *   DI - selector of the kernel data segment
 *
 * ABI of `kynox_gdt_load_code`:
 *   DI - selector of the kernel code segment
 *
 * ABI of `kynox_load_tss`:
 *   DI - selector of the task state segment
 *
 * ABI of `kynox_load_gdt` and `kynox_store_gdt`:
 *   RDI - address of the GDTR structure (16 bit limit followed by the 64 bit
 *         base address)
 *
 * Registers: the routines preserve every register they change, except for
 * the segment registers that they reload on purpose.
 * Side effects: `kynox_gdt_load_data` reloads `SS`, `DS`, `ES`, `FS` and
 * `GS`; `kynox_gdt_load_code` reloads `CS` with a far jump.
 */

.section .text

/*
 * Reloads the data segment registers.
 *
 * The data segments are reloaded before the code segment: the far jump that
 * follows needs a valid stack, which the current one already is.
 */
.global kynox_gdt_load_data
.type kynox_gdt_load_data, @function
kynox_gdt_load_data:
    movw %di, %ax
    movw %ax, %ss
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    ret
.size kynox_gdt_load_data, . - kynox_gdt_load_data

/*
 * Reloads the code segment.
 *
 * The code segment can only be changed with a far transfer. A far jump is
 * used instead of a far return because it does not touch the stack, which
 * removes one class of alignment problems.
 *
 * The far pointer holds the offset in the first quad word and the selector
 * in the second one. The selector is zero extended: the far pointer has a
 * full quad word for it and the upper bits have to be zero. The upper bits
 * of the argument register are undefined in the ABI.
 */
.global kynox_gdt_load_code
.type kynox_gdt_load_code, @function
kynox_gdt_load_code:
    leaq 1f(%rip), %rax
    movq %rax, kynox_far_pointer(%rip)
    movzwq %di, %rax
    movq %rax, kynox_far_pointer+8(%rip)
    ljmpq *kynox_far_pointer(%rip)
1:
    ret
.size kynox_gdt_load_code, . - kynox_gdt_load_code

/*
 * Loads the task state segment into the `TR` register.
 *
 * The instruction takes a sixteen bit selector. The assembler promotes a
 * register operand to the thirty two bit form, which is not the encoding
 * the instruction is defined with, therefore the selector is placed in
 * memory and the sixteen bit form of the instruction is used.
 */
.global kynox_load_tss
.type kynox_load_tss, @function
kynox_load_tss:
    movw %di, kynox_tss_selector(%rip)
    ltrw kynox_tss_selector(%rip)
    ret
.size kynox_load_tss, . - kynox_load_tss

/*
 * Loads the global descriptor table.
 */
.global kynox_load_gdt
.type kynox_load_gdt, @function
kynox_load_gdt:
    lgdt (%rdi)
    ret
.size kynox_load_gdt, . - kynox_load_gdt

/*
 * Stores the global descriptor table.
 */
.global kynox_store_gdt
.type kynox_store_gdt, @function
kynox_store_gdt:
    sgdt (%rdi)
    ret
.size kynox_store_gdt, . - kynox_store_gdt

/* The far pointer used by the reload of the code segment and the selector
 * used by the load of the task state segment. */
.section .bss
.align 8
.global kynox_far_pointer
kynox_far_pointer:
    .quad 0
    .quad 0
.global kynox_tss_selector
kynox_tss_selector:
    .word 0

/* The kernel does not use an executable stack. */
.section .note.GNU-stack,"",@progbits
