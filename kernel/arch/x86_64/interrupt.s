/**************************************************************************/
/*  interrupt.s                                                           */
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
 * Entry points of the interrupt and exception handlers.
 *
 * The stubs normalise the stack frame so that the handler in Zig always
 * receives the same layout:
 *
 *   - a word with the error code, zero when the exception does not push one;
 *   - the vector number;
 *   - the general purpose registers.
 *
 * The registers are saved in the order that leaves them in the frame with
 * the most recently saved register at the lowest address, which is the
 * natural order of a structure in memory.
 *
 * ABI of the handler:
 *   RDI - the vector number
 *   RSI - the address of the register frame
 *
 * Registers: the stubs restore every register they change. The stack is
 * balanced when the handler returns.
 * Side effects: the handler is called with interrupts disabled by the
 * processor, it is the responsibility of the handler to re-enable them.
 */

.section .text

/* Saves the general purpose registers that the processor does not save. */
.macro PUSH_REGISTERS
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %rbx
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
.endm

/*
 * Aligns the stack for the call of the handler.
 *
 * The convention of the system V of AMD64 asks for a stack pointer that is
 * a multiple of sixteen before the call, and the handler of Zig assumes
 * that it is the case.
 *
 * The processor does not leave the stack aligned when the interruption
 * comes from the kernel itself: the processor pushes the frame of the
 * return only when the privilege level changes, and the pushes of the stub
 * change the parity of the stack pointer. The interruption that comes from
 * the user mode leaves the stack aligned, and the padding is not pushed
 * for it.
 *
 * The macro has to be paired with UNALIGN_STACK, and the register of the
 * padding is the one that the convention of the call makes the callee
 * save.
 */
.macro ALIGN_STACK
    movq %rsp, %rax
    testq $8, %rax
    jz 901f
    pushq $0                  /* the padding */
    movq $1, %rbx
    jmp 902f
901:
    movq $0, %rbx
902:
.endm

/* Removes the padding that ALIGN_STACK pushed, if there was one. */
.macro UNALIGN_STACK
    testq %rbx, %rbx
    jz 903f
    addq $8, %rsp
903:
.endm

/* Restores the registers saved by PUSH_REGISTERS. */
.macro POP_REGISTERS
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbx
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rax
.endm

/*
 * Entry point of an exception that does not push an error code.
 *
 * The word that the processor pushed for the exceptions that do push one is
 * removed before the return, so the frame is always the same.
 */
.macro EXCEPTION_ENTRY number
    .global kynox_exception_\number
    .type kynox_exception_\number, @function
kynox_exception_\number:
    pushq $0
    pushq $\number
    PUSH_REGISTERS
    /* An exception without an error code leaves no code behind, and the
     * global is cleared so that a previous exception does not show up in
     * the report of this one. */
    movq $0, kynox_exception_error_code(%rip)
    movq $\number, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call kynox_exception_handler
    UNALIGN_STACK
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

/*
 * Entry point of an exception that pushes an error code.
 *
 * The error code of the processor is kept above the word that the stub
 * pushes, the handler reads it from the frame.
 */
.macro EXCEPTION_ENTRY_WITH_ERROR number
    .global kynox_exception_\number
    .type kynox_exception_\number, @function
kynox_exception_\number:
    pushq $0
    pushq $\number
    PUSH_REGISTERS
    /* The processor pushes the error code between the word of the vector
     * and the frame of the return, and the frame of an exception **with**
     * an error code has a shape that is different from the shape of the
     * frame of an interruption.
     *
     * The frame is normalized here: the error code is saved in a global,
     * and the five words of the return of the processor are moved down by
     * eight bytes. The handler, the switch of the context and the return of
     * the processor read the same offsets in the two cases, and the shape of
     * the frame stops being a concern of each call. */
    movq 136(%rsp), %rax
    movq %rax, kynox_exception_error_code(%rip)
    movq 144(%rsp), %rax
    movq %rax, 136(%rsp)
    movq 152(%rsp), %rax
    movq %rax, 144(%rsp)
    movq 160(%rsp), %rax
    movq %rax, 152(%rsp)
    movq 168(%rsp), %rax
    movq %rax, 160(%rsp)
    movq 176(%rsp), %rax
    movq %rax, 168(%rsp)
    movq $\number, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call kynox_exception_handler
    UNALIGN_STACK
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

/*
 * Entry point of a hardware interrupt.
 *
 * The frame has the same layout as the frame of an exception, the handler
 * returns to the interrupted code.
 */
.macro INTERRUPT_ENTRY number
    .global kynox_interrupt_\number
    .type kynox_interrupt_\number, @function
kynox_interrupt_\number:
    pushq $0
    pushq $\number
    PUSH_REGISTERS
    /* The state of the floating point unit and of the vector registers
     * belongs to the task that is interrupted, and the processor does not
     * save it in the long mode. The area is the one of the context of the
     * task, and the context is the one that the scheduler points at.
     *
     * The save happens here, at the entry of the interruption, and not in
     * the switch: the handler is written in Zig, and the code that it
     * runs uses the vector registers, and therefore it would save the state
     * that the interrupted task had left behind.
     *
     * The save comes after PUSH_REGISTERS because the instruction needs a
     * register to hold the address of the context, and every register of
     * the task is already saved in the frame at this point. */
    movq kynox_current_context(%rip), %rax
    testq %rax, %rax
    jz .Lskip_fp_save_\number
    fxsave64 192(%rax)
.Lskip_fp_save_\number:
    movq $\number, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call kynox_interrupt_handler
    UNALIGN_STACK
    /* The handler returns zero to resume the interrupted code, and a value
     * different from zero to switch to another task. The switch reads the
     * frame that is still on the stack, so it is entered with a jump and not
     * with a call: a call would move the frame. */
    testq %rax, %rax
    jz 1f
    jmp kynox_task_switch
1:
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

/*
 * Entry point of the vectors that the kernel does not handle.
 */
.macro EXCEPTION_ENTRY_UNEXPECTED
    .global kynox_exception_unexpected
    .type kynox_exception_unexpected, @function
kynox_exception_unexpected:
    pushq $0
    pushq $255
    PUSH_REGISTERS
    movq $255, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call kynox_exception_handler
    UNALIGN_STACK
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

EXCEPTION_ENTRY 0
EXCEPTION_ENTRY 1
EXCEPTION_ENTRY 2
EXCEPTION_ENTRY 3
EXCEPTION_ENTRY 4
EXCEPTION_ENTRY 5
EXCEPTION_ENTRY 6
EXCEPTION_ENTRY 7
EXCEPTION_ENTRY_WITH_ERROR 8
EXCEPTION_ENTRY 9
EXCEPTION_ENTRY_WITH_ERROR 10
EXCEPTION_ENTRY_WITH_ERROR 11
EXCEPTION_ENTRY_WITH_ERROR 12
EXCEPTION_ENTRY_WITH_ERROR 13
EXCEPTION_ENTRY_WITH_ERROR 14
EXCEPTION_ENTRY 15
EXCEPTION_ENTRY 16
EXCEPTION_ENTRY_WITH_ERROR 17
EXCEPTION_ENTRY 18
EXCEPTION_ENTRY 19
EXCEPTION_ENTRY 20
EXCEPTION_ENTRY_WITH_ERROR 21
EXCEPTION_ENTRY 22
EXCEPTION_ENTRY 23
EXCEPTION_ENTRY 24
EXCEPTION_ENTRY 25
EXCEPTION_ENTRY 26
EXCEPTION_ENTRY 27
EXCEPTION_ENTRY 28
EXCEPTION_ENTRY 29
EXCEPTION_ENTRY 30
EXCEPTION_ENTRY 31

INTERRUPT_ENTRY 32
INTERRUPT_ENTRY 33
INTERRUPT_ENTRY 34
INTERRUPT_ENTRY 35
INTERRUPT_ENTRY 36
INTERRUPT_ENTRY 37
INTERRUPT_ENTRY 38
INTERRUPT_ENTRY 39
INTERRUPT_ENTRY 40
INTERRUPT_ENTRY 41
INTERRUPT_ENTRY 42
INTERRUPT_ENTRY 43
INTERRUPT_ENTRY 44
INTERRUPT_ENTRY 45
INTERRUPT_ENTRY 46
INTERRUPT_ENTRY 47

INTERRUPT_ENTRY 64
INTERRUPT_ENTRY 65
INTERRUPT_ENTRY 66
INTERRUPT_ENTRY 67

/* The device vectors: one stub per vector from 68 to 254.
 *
 * A device that interrupts with a message (MSI, MSI-X) names the vector it
 * wants, and the kernel reserves the range above the ones it uses for itself.
 * Each vector needs an entry point of its own because the entry point is what
 * tells the handler which vector arrived: a shared stub could not.
 */
INTERRUPT_ENTRY 68
INTERRUPT_ENTRY 69
INTERRUPT_ENTRY 70
INTERRUPT_ENTRY 71
INTERRUPT_ENTRY 72
INTERRUPT_ENTRY 73
INTERRUPT_ENTRY 74
INTERRUPT_ENTRY 75
INTERRUPT_ENTRY 76
INTERRUPT_ENTRY 77
INTERRUPT_ENTRY 78
INTERRUPT_ENTRY 79
INTERRUPT_ENTRY 80
INTERRUPT_ENTRY 81
INTERRUPT_ENTRY 82
INTERRUPT_ENTRY 83
INTERRUPT_ENTRY 84
INTERRUPT_ENTRY 85
INTERRUPT_ENTRY 86
INTERRUPT_ENTRY 87
INTERRUPT_ENTRY 88
INTERRUPT_ENTRY 89
INTERRUPT_ENTRY 90
INTERRUPT_ENTRY 91
INTERRUPT_ENTRY 92
INTERRUPT_ENTRY 93
INTERRUPT_ENTRY 94
INTERRUPT_ENTRY 95
INTERRUPT_ENTRY 96
INTERRUPT_ENTRY 97
INTERRUPT_ENTRY 98
INTERRUPT_ENTRY 99
INTERRUPT_ENTRY 100
INTERRUPT_ENTRY 101
INTERRUPT_ENTRY 102
INTERRUPT_ENTRY 103
INTERRUPT_ENTRY 104
INTERRUPT_ENTRY 105
INTERRUPT_ENTRY 106
INTERRUPT_ENTRY 107
INTERRUPT_ENTRY 108
INTERRUPT_ENTRY 109
INTERRUPT_ENTRY 110
INTERRUPT_ENTRY 111
INTERRUPT_ENTRY 112
INTERRUPT_ENTRY 113
INTERRUPT_ENTRY 114
INTERRUPT_ENTRY 115
INTERRUPT_ENTRY 116
INTERRUPT_ENTRY 117
INTERRUPT_ENTRY 118
INTERRUPT_ENTRY 119
INTERRUPT_ENTRY 120
INTERRUPT_ENTRY 121
INTERRUPT_ENTRY 122
INTERRUPT_ENTRY 123
INTERRUPT_ENTRY 124
INTERRUPT_ENTRY 125
INTERRUPT_ENTRY 126
INTERRUPT_ENTRY 127
INTERRUPT_ENTRY 128
INTERRUPT_ENTRY 129
INTERRUPT_ENTRY 130
INTERRUPT_ENTRY 131
INTERRUPT_ENTRY 132
INTERRUPT_ENTRY 133
INTERRUPT_ENTRY 134
INTERRUPT_ENTRY 135
INTERRUPT_ENTRY 136
INTERRUPT_ENTRY 137
INTERRUPT_ENTRY 138
INTERRUPT_ENTRY 139
INTERRUPT_ENTRY 140
INTERRUPT_ENTRY 141
INTERRUPT_ENTRY 142
INTERRUPT_ENTRY 143
INTERRUPT_ENTRY 144
INTERRUPT_ENTRY 145
INTERRUPT_ENTRY 146
INTERRUPT_ENTRY 147
INTERRUPT_ENTRY 148
INTERRUPT_ENTRY 149
INTERRUPT_ENTRY 150
INTERRUPT_ENTRY 151
INTERRUPT_ENTRY 152
INTERRUPT_ENTRY 153
INTERRUPT_ENTRY 154
INTERRUPT_ENTRY 155
INTERRUPT_ENTRY 156
INTERRUPT_ENTRY 157
INTERRUPT_ENTRY 158
INTERRUPT_ENTRY 159
INTERRUPT_ENTRY 160
INTERRUPT_ENTRY 161
INTERRUPT_ENTRY 162
INTERRUPT_ENTRY 163
INTERRUPT_ENTRY 164
INTERRUPT_ENTRY 165
INTERRUPT_ENTRY 166
INTERRUPT_ENTRY 167
INTERRUPT_ENTRY 168
INTERRUPT_ENTRY 169
INTERRUPT_ENTRY 170
INTERRUPT_ENTRY 171
INTERRUPT_ENTRY 172
INTERRUPT_ENTRY 173
INTERRUPT_ENTRY 174
INTERRUPT_ENTRY 175
INTERRUPT_ENTRY 176
INTERRUPT_ENTRY 177
INTERRUPT_ENTRY 178
INTERRUPT_ENTRY 179
INTERRUPT_ENTRY 180
INTERRUPT_ENTRY 181
INTERRUPT_ENTRY 182
INTERRUPT_ENTRY 183
INTERRUPT_ENTRY 184
INTERRUPT_ENTRY 185
INTERRUPT_ENTRY 186
INTERRUPT_ENTRY 187
INTERRUPT_ENTRY 188
INTERRUPT_ENTRY 189
INTERRUPT_ENTRY 190
INTERRUPT_ENTRY 191
INTERRUPT_ENTRY 192
INTERRUPT_ENTRY 193
INTERRUPT_ENTRY 194
INTERRUPT_ENTRY 195
INTERRUPT_ENTRY 196
INTERRUPT_ENTRY 197
INTERRUPT_ENTRY 198
INTERRUPT_ENTRY 199
INTERRUPT_ENTRY 200
INTERRUPT_ENTRY 201
INTERRUPT_ENTRY 202
INTERRUPT_ENTRY 203
INTERRUPT_ENTRY 204
INTERRUPT_ENTRY 205
INTERRUPT_ENTRY 206
INTERRUPT_ENTRY 207
INTERRUPT_ENTRY 208
INTERRUPT_ENTRY 209
INTERRUPT_ENTRY 210
INTERRUPT_ENTRY 211
INTERRUPT_ENTRY 212
INTERRUPT_ENTRY 213
INTERRUPT_ENTRY 214
INTERRUPT_ENTRY 215
INTERRUPT_ENTRY 216
INTERRUPT_ENTRY 217
INTERRUPT_ENTRY 218
INTERRUPT_ENTRY 219
INTERRUPT_ENTRY 220
INTERRUPT_ENTRY 221
INTERRUPT_ENTRY 222
INTERRUPT_ENTRY 223
INTERRUPT_ENTRY 224
INTERRUPT_ENTRY 225
INTERRUPT_ENTRY 226
INTERRUPT_ENTRY 227
INTERRUPT_ENTRY 228
INTERRUPT_ENTRY 229
INTERRUPT_ENTRY 230
INTERRUPT_ENTRY 231
INTERRUPT_ENTRY 232
INTERRUPT_ENTRY 233
INTERRUPT_ENTRY 234
INTERRUPT_ENTRY 235
INTERRUPT_ENTRY 236
INTERRUPT_ENTRY 237
INTERRUPT_ENTRY 238
INTERRUPT_ENTRY 239
INTERRUPT_ENTRY 240
INTERRUPT_ENTRY 241
INTERRUPT_ENTRY 242
INTERRUPT_ENTRY 243
INTERRUPT_ENTRY 244
INTERRUPT_ENTRY 245
INTERRUPT_ENTRY 246
INTERRUPT_ENTRY 247
INTERRUPT_ENTRY 248
INTERRUPT_ENTRY 249
INTERRUPT_ENTRY 250
INTERRUPT_ENTRY 251
INTERRUPT_ENTRY 252
INTERRUPT_ENTRY 253
INTERRUPT_ENTRY 254

/*
 * The addresses of the stubs above, in vector order: entry N is vector
 * 68 + N.
 *
 * The table lives here so that the kernel installs a hundred and eighty-seven
 * gates without declaring a hundred and eighty-seven externs: the assembly
 * knows its own symbols, and Zig only indexes the table.
 */
.section .data, "aw"
.balign 8
.global kynox_device_stub_table
.type kynox_device_stub_table, @object
kynox_device_stub_table:
    .quad kynox_interrupt_68
    .quad kynox_interrupt_69
    .quad kynox_interrupt_70
    .quad kynox_interrupt_71
    .quad kynox_interrupt_72
    .quad kynox_interrupt_73
    .quad kynox_interrupt_74
    .quad kynox_interrupt_75
    .quad kynox_interrupt_76
    .quad kynox_interrupt_77
    .quad kynox_interrupt_78
    .quad kynox_interrupt_79
    .quad kynox_interrupt_80
    .quad kynox_interrupt_81
    .quad kynox_interrupt_82
    .quad kynox_interrupt_83
    .quad kynox_interrupt_84
    .quad kynox_interrupt_85
    .quad kynox_interrupt_86
    .quad kynox_interrupt_87
    .quad kynox_interrupt_88
    .quad kynox_interrupt_89
    .quad kynox_interrupt_90
    .quad kynox_interrupt_91
    .quad kynox_interrupt_92
    .quad kynox_interrupt_93
    .quad kynox_interrupt_94
    .quad kynox_interrupt_95
    .quad kynox_interrupt_96
    .quad kynox_interrupt_97
    .quad kynox_interrupt_98
    .quad kynox_interrupt_99
    .quad kynox_interrupt_100
    .quad kynox_interrupt_101
    .quad kynox_interrupt_102
    .quad kynox_interrupt_103
    .quad kynox_interrupt_104
    .quad kynox_interrupt_105
    .quad kynox_interrupt_106
    .quad kynox_interrupt_107
    .quad kynox_interrupt_108
    .quad kynox_interrupt_109
    .quad kynox_interrupt_110
    .quad kynox_interrupt_111
    .quad kynox_interrupt_112
    .quad kynox_interrupt_113
    .quad kynox_interrupt_114
    .quad kynox_interrupt_115
    .quad kynox_interrupt_116
    .quad kynox_interrupt_117
    .quad kynox_interrupt_118
    .quad kynox_interrupt_119
    .quad kynox_interrupt_120
    .quad kynox_interrupt_121
    .quad kynox_interrupt_122
    .quad kynox_interrupt_123
    .quad kynox_interrupt_124
    .quad kynox_interrupt_125
    .quad kynox_interrupt_126
    .quad kynox_interrupt_127
    .quad kynox_interrupt_128
    .quad kynox_interrupt_129
    .quad kynox_interrupt_130
    .quad kynox_interrupt_131
    .quad kynox_interrupt_132
    .quad kynox_interrupt_133
    .quad kynox_interrupt_134
    .quad kynox_interrupt_135
    .quad kynox_interrupt_136
    .quad kynox_interrupt_137
    .quad kynox_interrupt_138
    .quad kynox_interrupt_139
    .quad kynox_interrupt_140
    .quad kynox_interrupt_141
    .quad kynox_interrupt_142
    .quad kynox_interrupt_143
    .quad kynox_interrupt_144
    .quad kynox_interrupt_145
    .quad kynox_interrupt_146
    .quad kynox_interrupt_147
    .quad kynox_interrupt_148
    .quad kynox_interrupt_149
    .quad kynox_interrupt_150
    .quad kynox_interrupt_151
    .quad kynox_interrupt_152
    .quad kynox_interrupt_153
    .quad kynox_interrupt_154
    .quad kynox_interrupt_155
    .quad kynox_interrupt_156
    .quad kynox_interrupt_157
    .quad kynox_interrupt_158
    .quad kynox_interrupt_159
    .quad kynox_interrupt_160
    .quad kynox_interrupt_161
    .quad kynox_interrupt_162
    .quad kynox_interrupt_163
    .quad kynox_interrupt_164
    .quad kynox_interrupt_165
    .quad kynox_interrupt_166
    .quad kynox_interrupt_167
    .quad kynox_interrupt_168
    .quad kynox_interrupt_169
    .quad kynox_interrupt_170
    .quad kynox_interrupt_171
    .quad kynox_interrupt_172
    .quad kynox_interrupt_173
    .quad kynox_interrupt_174
    .quad kynox_interrupt_175
    .quad kynox_interrupt_176
    .quad kynox_interrupt_177
    .quad kynox_interrupt_178
    .quad kynox_interrupt_179
    .quad kynox_interrupt_180
    .quad kynox_interrupt_181
    .quad kynox_interrupt_182
    .quad kynox_interrupt_183
    .quad kynox_interrupt_184
    .quad kynox_interrupt_185
    .quad kynox_interrupt_186
    .quad kynox_interrupt_187
    .quad kynox_interrupt_188
    .quad kynox_interrupt_189
    .quad kynox_interrupt_190
    .quad kynox_interrupt_191
    .quad kynox_interrupt_192
    .quad kynox_interrupt_193
    .quad kynox_interrupt_194
    .quad kynox_interrupt_195
    .quad kynox_interrupt_196
    .quad kynox_interrupt_197
    .quad kynox_interrupt_198
    .quad kynox_interrupt_199
    .quad kynox_interrupt_200
    .quad kynox_interrupt_201
    .quad kynox_interrupt_202
    .quad kynox_interrupt_203
    .quad kynox_interrupt_204
    .quad kynox_interrupt_205
    .quad kynox_interrupt_206
    .quad kynox_interrupt_207
    .quad kynox_interrupt_208
    .quad kynox_interrupt_209
    .quad kynox_interrupt_210
    .quad kynox_interrupt_211
    .quad kynox_interrupt_212
    .quad kynox_interrupt_213
    .quad kynox_interrupt_214
    .quad kynox_interrupt_215
    .quad kynox_interrupt_216
    .quad kynox_interrupt_217
    .quad kynox_interrupt_218
    .quad kynox_interrupt_219
    .quad kynox_interrupt_220
    .quad kynox_interrupt_221
    .quad kynox_interrupt_222
    .quad kynox_interrupt_223
    .quad kynox_interrupt_224
    .quad kynox_interrupt_225
    .quad kynox_interrupt_226
    .quad kynox_interrupt_227
    .quad kynox_interrupt_228
    .quad kynox_interrupt_229
    .quad kynox_interrupt_230
    .quad kynox_interrupt_231
    .quad kynox_interrupt_232
    .quad kynox_interrupt_233
    .quad kynox_interrupt_234
    .quad kynox_interrupt_235
    .quad kynox_interrupt_236
    .quad kynox_interrupt_237
    .quad kynox_interrupt_238
    .quad kynox_interrupt_239
    .quad kynox_interrupt_240
    .quad kynox_interrupt_241
    .quad kynox_interrupt_242
    .quad kynox_interrupt_243
    .quad kynox_interrupt_244
    .quad kynox_interrupt_245
    .quad kynox_interrupt_246
    .quad kynox_interrupt_247
    .quad kynox_interrupt_248
    .quad kynox_interrupt_249
    .quad kynox_interrupt_250
    .quad kynox_interrupt_251
    .quad kynox_interrupt_252
    .quad kynox_interrupt_253
    .quad kynox_interrupt_254
.size kynox_device_stub_table, . - kynox_device_stub_table
.text

EXCEPTION_ENTRY_UNEXPECTED

/*
 * Loads the interrupt descriptor table.
 *
 * ABI:
 *   RDI - address of the IDTR structure (16 bit limit followed by the
 *         64 bit base address).
 */
.global kynox_load_idt
.type kynox_load_idt, @function
kynox_load_idt:
    lidt (%rdi)
    ret
.size kynox_load_idt, . - kynox_load_idt

/*
 * Stores the interrupt descriptor table.
 *
 * ABI:
 *   RDI - address of the IDTR structure that receives the values.
 */
.global kynox_store_idt
.type kynox_store_idt, @function
kynox_store_idt:
    sidt (%rdi)
    ret
.size kynox_store_idt, . - kynox_store_idt

/* The error code of the last exception that pushed one.
 *
 * The stub of an exception with an error code saves the code here before it
 * normalizes the frame, and the handler reads the code from here. */
.section .bss
.align 8
.global kynox_exception_error_code
.type kynox_exception_error_code, @object
kynox_exception_error_code:
    .quad 0

/* The kernel does not use an executable stack. */
.section .note.GNU-stack,"",@progbits
