/* Linker script for a higher-half x86_64 kernel loaded by Limine. */

/* Tell the linker which symbol is the entry point. Limine reads this from
   the ELF header and jumps to it after setting up long mode. */
ENTRY(kmain)

/* Emit a standard ELF executable, not a relocatable object or shared lib. */
OUTPUT_FORMAT(elf64-x86-64)

PHDRS
{
    /* One program header per protection class. Limine maps each PT_LOAD
       segment with the matching permissions. Keeping .text non-writable
       and .data/.bss non-executable is what makes W^X work. */
    text    PT_LOAD FLAGS((1 << 0) | (1 << 2)) ; /* R + X */
    rodata  PT_LOAD FLAGS((1 << 2)) ;            /* R     */
    data    PT_LOAD FLAGS((1 << 1) | (1 << 2)) ; /* R + W */
}

SECTIONS
{
    /* Higher-half kernel base. The top 2 GiB of the 64-bit address space
       is the conventional home for kernel code on x86_64; user space gets
       the lower half. Limine maps the kernel here for us. */
    . = 0xffffffff80000000;

    .text : {
        *(.text .text.*)
    } :text

    /* Page-align before changing permissions, otherwise the loader would
       have to map a page as both executable and read-only. */
    . = ALIGN(4K);

    /* Limine requests live in rodata. KEEP() prevents the linker's
       --gc-sections from discarding them, since nothing in our C++ code
       references them by name. The start/end markers must bracket the
       requests block so Limine's scanner can find the boundaries. */
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :rodata

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4K);

    .data : {
        *(.data .data.*)
    } :data

    /* .bss holds zero-initialized globals. It takes no space in the file
       but the loader must allocate and zero it at load time. */
    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    } :data

    /* Drop sections we don't need in the final binary: debug info, notes,
       comments, exception-handling tables. Keeps the kernel image small. */
    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
    }
}
