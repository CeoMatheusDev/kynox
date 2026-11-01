//************************************************************************//
//  cpu.s                                                                 //
//************************************************************************//
//                         This file is part of:                          //
//                               Kynox                                  //
//              https://github.com/CeoMatheusDev/Kynox                  //
//************************************************************************//
// Copyright (C) 2026 Kynox contributors.                               //
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
// Copyright (C) 2026 Kynox - All Rights Reserved.
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

/*
 * The instructions of the processor that need an explicit memory operand
 * are written here. The inline assembler of Zig refuses `invlpg` with a
 * register operand in a debug build, and the instruction is the one that
 * removes the stale translation of a page after the kernel changes its
 * permissions.
 */

.text

/*
 * Invalidates the translation of the page that contains the address.
 *
 * The System V ABI passes the first argument in RDI, and the instruction
 * reads the address from a register as an effective address. The function
 * does not return a value.
 */
.global kynox_invlpg
.type kynox_invlpg, @function
kynox_invlpg:
    invlpg (%rdi)
    ret
.size kynox_invlpg, . - kynox_invlpg

/*
 * Empties the TLB of the processor.
 *
 * x86-64 has no instruction that flushes the whole TLB from the kernel; the
 * architectural sequence is to read the page directory base register and write
 * the same value back, which invalidates every cached translation that is not
 * marked global. Clobbering RAX is allowed: it is a scratch register of the
 * System V ABI and the function returns nothing.
 */
.global kynox_flush_tlb
.type kynox_flush_tlb, @function
kynox_flush_tlb:
    movq %cr3, %rax
    movq %rax, %cr3
    ret
.size kynox_flush_tlb, . - kynox_flush_tlb
