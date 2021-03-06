/*
 * 64bit.S - code for entering 64-bit mode.
 *
 * Author: Per Lundberg <per@halleluja.nu> 
 * Copyright: (C) 2008-2009 Per Lundberg
 */

#include "64bit.h"
#include <common/vm.h>
        
        .text
        .code32
        
        // This makes GNU assembler behave a bit more like MASM, TASM and NASM -- in other words, conventional x86
        // assemblers.
        .intel_syntax noprefix
        
        .globl _64bit_init

        // This code is more or less a rip-off of the sample code in the AMD64 Architecture Programmers Manual, Volume 2. 
        // (page 361 and onwards). What I've done is minor modifications.
        
_64bit_init:

        // First, detect a 64-bit CPU.
        mov     eax, 0x80000000         // Extended function 0x80000000
        cpuid                           // Get the largest extended function.
        cmp     eax, 0x80000000         // Do we have any function > 0x80000000?
        jbe     no_long_mode            // If not, long mode is not supported.
        mov     eax, 0x80000001         // Extended function 0x80000001
        cpuid                           // EDX = extended features flags.
        bt      edx, 29                 // Test for bit 29.
        jnc     no_long_mode            // If it's not set, long mode isn't supported
        jmp     has_long_mode

no_long_mode:
        push    dword ptr _non64bit_cpu_message
        call    io_print_line
halt:   jmp     halt

has_long_mode:  
        // OK, 64-bit (long mode) is supported. Let's get moving. We start off by setting enabling PAE (Page Address
        // Extensions) -- a requirement before entering long mode. This is done by setting CR4.PAE = 1.
        mov     eax, cr4
        bts     eax, 5
        mov     cr4, eax
       
        // This defines one 2 MiB identity-mapped page at the start of memory (so we can access the first 2 megs of
        // RAM just like we would if paging/long mode was not in place). The kernel code and data is assumed to be
        // located within this page, as well as the 64-bit kernel.

        // First the PML4.
        cld
        mov     edi, 0xA000

        mov     eax, 0xB00F
        stosd

        xor     eax, eax
        mov     ecx, 0x03FF
        rep     stosd

        // Then the page directory.
        mov     eax, 0xC00F
        stosd

        xor     eax, eax
        mov     ecx, 0x03FF
        rep     stosd

        // Then, finally, the page tables.
        mov     ax, 0x018F
        stosd

        xor     eax, eax
        mov     ecx, 0x03FF
        rep     stosd
                
        // Load the address of this newly set up paging structure into CR3.
        mov     eax, VM_STRUCTURES_PML4_ADDRESS
        mov     cr3, eax
       
        // Enable long mode (set EFER.LME = 1).
        mov     ecx, 0xC0000080         // EFER MSR number.
        rdmsr                
        bts     eax, 8                  //  Set LME = 1.
        wrmsr
       
        // Enable paging to activate long mode. This is done by setting CR0.PG = 1.
        mov     eax, cr0
        bts     eax, 31                 //  Set PE = 1
        mov     cr0, eax

        // We are now in 32-bit "compatibility mode". Let's do one more thing before jumping into 64-bit mode:  Set up
        // a new GDT, Global Descriptor Table. First, copy it over to its designated place.
        mov     esi, offset gdt
        mov     edi, 0x1000
        mov     ecx, 8 * 3
        rep     movsb
       
        // ...then, load the GDTR register.
        lgdt    gdt_pointer

        // Now, let's jump into the 64-bit code segment. This one is a bit tricky to have GAS assemble correctly so
        // we hardcode the opcodes instead. :)
        .byte   0xEA                    // jmp far
        .long   _64bit_entry_point
        .word   8                       // 64-bit code selector. Shift off the last 3 bits of this and you get the
                                        // index of the selector in the GDT.

        .code64
_64bit_entry_point:
        
        // Now, call the 64-bit kernel. When this method (_64bit_init) was called, we received an argument that
        // is a pointed to the Multiboot header. We want to pass this header on to the 64-bit kernel. Now, for those of you
        // who are a bit used to 32-bit assembly/low-level programming, here comes something new (at least it was for me):
        // On amd64, you don't push integers on the stack. Instead, you pass it using a register. There is a list of the order
        // of those registers specified in the System V ABI for AMD64, located at this URL:
        //
        // http://refspecs.linuxbase.org/elf/x86_64-abi-0.99.pdf
        //
        // For now, we only need to know and accept that RDI is the first and RSI is the second integer-parameter
        // register. :)
        mov     edi, dword ptr [esp + 4]                // Upper 32-bits are automatically cleansed by this op.
        mov     rsi, qword ptr [esp + 8]
        
        mov     rax, _64BIT_KERNEL_ENTRY_POINT          // We can't just call this address directly, there doesn't seem
        call    rax                                     // to be such an instruction... so we go via a register.
                    
        .data
_non64bit_cpu_message:      
        .asciz  "The CPU does not support 64-bit mode. Kernel halted."
        
        // Reference to the gdt , which we load so we can perform the jump into hyperspace... ehh, I mean, 64-bit code. :-)
        // We set the limit to 0xFFFF = 
gdt_pointer:
        .word   3 * 8                   // The size of the GDT, in bytes. We only need three descriptors à 8 bytes.
        .long   0x1000                  // The location of the GDT. We place it at the second page in memory (4 KiB).
        
        // FIXME: having these hardwired like this makes it extremely ugly and hard to see what this says... Perhaps we
        // should even create the GDT from a C function to make it more obvious what they look like.
gdt:    .quad   0x0000000000000000      // Null descriptor.
        .quad   0x0020980000000000      // Code descriptor..
        .quad   0x0000900000000000      // Data descriptor..
