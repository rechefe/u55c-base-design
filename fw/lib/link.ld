/* Firmware memory layout: everything in the 256 KB program RAM at 0x0. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 256K
}

STACK_SIZE = 16K;

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > RAM

    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM

    .data : {
        . = ALIGN(4);
        __global_pointer$ = . + 0x800;
        *(.data .data.* .sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(__bss_end + STACK_SIZE <= __stack_top, "firmware too large for 256 KB RAM")
}
