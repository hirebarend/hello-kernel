# hello-kernel

This project is the kernel-side counterpart to the `std::cout << "Hello World!\n";` you would write in a typical C++ program. Same printable result, but no userspace, no libc, no operating system underneath us. We are the operating system, and we are talking to the serial port directly.

## From `std::cout` to a serial port

Before we touch any kernel code, it is worth tracing what a normal `std::cout << "Hello World!\n";` actually does on a Linux box.

`std::cout << "Hello World!\n";` places the bytes `Hello World!\n` in user-space memory, usually through the C++ stream buffering system. When the stream is flushed, the C/C++ runtime makes a `write` syscall, passing Linux a file descriptor (typically `1` for stdout), a pointer to the user-space buffer, and the number of bytes to write. If fd 1 is connected to `/dev/ttyS0`, Linux routes the write through the TTY/serial subsystem to the serial driver. For a classic x86 COM1 UART, the serial driver eventually writes those bytes to the UART's I/O ports, typically using an `outb`-style instruction targeting the base port `0x3F8`.

So there are several layers between `std::cout` and the wire: the stream buffer, the syscall boundary, the TTY layer, the serial driver, and finally the UART. All of them exist because user space is not allowed to issue privileged I/O instructions like `outb` on its own. Only the kernel can.

In this project we cut every one of those layers out. We boot a tiny kernel and write `Hello, World!` to COM1 ourselves. The actual I/O turns out to be the easy part. The bulk of the work is "what does it take to have a kernel at all".

## What "the kernel" means here

When the CPU starts or resets it begins executing firmware code from a fixed reset location. On a modern PC that firmware is UEFI. UEFI initializes the system, discovers bootable devices, and loads a bootloader as an EFI application. In our case, that bootloader is [Limine](https://limine-bootloader.org/).

Limine reads its config, loads the kernel file specified there, parses the kernel's executable format (ELF), finds the entry point, prepares some boot information, and jumps to that entry point.

Our kernel's entry point is `kmain` in `main.cpp`:

```cpp
extern "C" [[noreturn]] void kmain() {
    serial_init();
    serial_write("Hello, World!\n");
    hang();
}
```

Three things to notice:

- `extern "C"` keeps the symbol named exactly `kmain`, with no C++ name mangling, so Limine can find it.
- `[[noreturn]]` because there is no caller to return to. The stack above us is bootloader scratch.
- This function runs in long mode, in the kernel half of the address space, with no libc, no C++ runtime, no exceptions, no RTTI.

The rest of the README walks through `serial_init`, the Limine handshake, and what we have to do to the compiler, linker, and ISO image to make this binary actually boot.

## Talking to COM1 directly

x86 has a separate I/O address space from regular memory. To reach legacy devices like the 16550 UART you have to use the `outb` and `inb` instructions, which have no C equivalent, so we drop to inline assembly:

```cpp
constexpr uint16_t COM1 = 0x3F8;

inline void outb(uint16_t port, uint8_t val) {
    asm volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

inline uint8_t inb(uint16_t port) {
    uint8_t ret;
    asm volatile ("inb %1, %0" : "=a"(ret) : "Nd"(port));
    return ret;
}
```

The `"a"` constraint pins the value to the `AL` register, which is what `outb`/`inb` use. `"Nd"` lets the assembler take the port either as an immediate or in `DX`.

`COM1` is the legacy base address for the first serial port. The UART exposes a small bank of registers at `COM1 + 0` through `COM1 + 7`. Configuring it for 38400 baud, 8 data bits, no parity, 1 stop bit looks like this:

```cpp
void serial_init() {
    outb(COM1 + 1, 0x00); // IER: disable all UART interrupts (we poll instead)
    outb(COM1 + 3, 0x80); // LCR: set DLAB so the next two writes set the baud divisor
    outb(COM1 + 0, 0x03); // DLL: divisor low byte  -> 115200 / 3 = 38400 baud
    outb(COM1 + 1, 0x00); // DLM: divisor high byte
    outb(COM1 + 3, 0x03); // LCR: clear DLAB, set 8 bits / no parity / 1 stop bit
    outb(COM1 + 2, 0xC7); // FCR: enable FIFO, clear RX/TX queues, 14-byte trigger
    outb(COM1 + 4, 0x0B); // MCR: assert DTR + RTS, enable OUT2 (needed for IRQs later)
}
```

The numbers are register offsets and bit patterns straight from the 16550 datasheet. We do this once at boot.

Sending a byte is then a busy-wait on bit 5 of the Line Status Register (offset 5), which means "Transmit Holding Register Empty":

```cpp
void serial_putc(char c) {
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, static_cast<uint8_t>(c));
}

void serial_write(const char* s) {
    for (; *s; ++s) serial_putc(*s);
}
```

Polling is fine here because we have no scheduler yet. There is literally nothing else for the CPU to do.

## Halting cleanly

Once we have written our string, we have to park the CPU. There is nothing to return to.

```cpp
[[noreturn]] void hang() {
    for (;;) {
        asm volatile ("cli; hlt");
    }
}
```

`cli` masks maskable interrupts, `hlt` parks the CPU until the next one. With interrupts disabled, `hlt` effectively sleeps forever. The loop is there because non-maskable interrupts (NMIs) and System Management Interrupts (SMIs) can still wake the CPU past a single `hlt`. We just go back to sleep.

## How Limine finds us: the request structs

Limine is told which kernel file to load by its config, but it also needs to know which version of its boot protocol we speak and what we want it to set up before jumping to `kmain`. We communicate that by embedding specific structs in the kernel binary. Limine scans the loaded image for them by magic number and fills in their `response` fields before transferring control.

```cpp
__attribute__((used, section(".limine_requests")))
static volatile LIMINE_BASE_REVISION(3);

__attribute__((used, section(".limine_requests")))
static volatile struct limine_framebuffer_request framebuffer_request = {
    .id = LIMINE_FRAMEBUFFER_REQUEST,
    .revision = 0,
    .response = nullptr,
};

__attribute__((used, section(".limine_requests_start")))
static volatile LIMINE_REQUESTS_START_MARKER;

__attribute__((used, section(".limine_requests_end")))
static volatile LIMINE_REQUESTS_END_MARKER;
```

A few subtleties packed into those four declarations:

- `used` tells the compiler to emit the symbol even though no C++ code references it. Without this, the optimizer would happily delete them.
- `section(".limine_requests")` puts them into a dedicated linker section so the linker script can pin them to a known place in the binary.
- The `_start` and `_end` markers bracket the request list so Limine's scanner knows where to stop. They live in their own sections so we can place them immediately before and after the requests block.
- `LIMINE_BASE_REVISION(3)` declares which revision of the boot protocol we speak. Without it, Limine considers the kernel incompatible and refuses to boot.
- The framebuffer request is here mostly as a sanity check. We do not actually draw to the framebuffer in this hello world, but having a real request that Limine fills in is the simplest end-to-end proof that our struct layout works.

For the linker to keep these around through `--gc-sections`, we will need a `KEEP()` directive in `linker.ld`. We will get to that in a moment.

## Compiling freestanding

Now we have a `main.cpp`. Turning it into something that can run as a kernel needs some non-default compiler flags:

```bash
clang++ --target=x86_64-elf \
    -ffreestanding -fno-exceptions -fno-rtti \
    -fno-stack-protector -mno-red-zone -mcmodel=kernel \
    -Wall -Wextra \
    -c main.cpp -o build/main.o
```

What each flag is doing:

- `--target=x86_64-elf` cross-compiles for a bare x86_64 ELF target instead of whatever the host happens to be (macOS Mach-O, in our case).
- `-ffreestanding` tells the compiler we are not running on a hosted C/C++ implementation. There is no libc, `main`, signal handling, or standard library available. The compiler will not assume calls to `memcpy`/`memset` are linkable from libc.
- `-fno-exceptions -fno-rtti` strips C++ features that need runtime support we have not built (unwinder, type info tables).
- `-fno-stack-protector` disables stack canaries, which would otherwise reference symbols from a runtime that does not exist.
- `-mno-red-zone` disables the SysV ABI's 128-byte red zone below `%rsp`. Interrupt handlers in kernel mode can clobber that area, so kernels must not use it.
- `-mcmodel=kernel` tells the code generator that our code lives in the upper 2 GiB of the address space, so it should use the right addressing mode for global symbols.

This produces `build/main.o`, an object file: machine code plus symbols, sections, and relocation information. It is not an executable yet.

## Linking into a higher-half ELF

Linking turns the object file into a real ELF kernel image:

```bash
ld.lld -nostdlib -static -T linker.ld -o build/kernel.elf build/main.o
```

`-nostdlib` keeps the linker from pulling in any startup files or libc. `-static` produces a fully resolved binary with no dynamic dependencies. The interesting work happens in `linker.ld`:

```ld
ENTRY(kmain)
OUTPUT_FORMAT(elf64-x86-64)

PHDRS
{
    text    PT_LOAD FLAGS((1 << 0) | (1 << 2)) ; /* R + X */
    rodata  PT_LOAD FLAGS((1 << 2)) ;            /* R     */
    data    PT_LOAD FLAGS((1 << 1) | (1 << 2)) ; /* R + W */
}

SECTIONS
{
    . = 0xffffffff80000000;

    .text : { *(.text .text.*) } :text
    . = ALIGN(4K);

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :rodata

    .rodata : { *(.rodata .rodata.*) } :rodata
    . = ALIGN(4K);

    .data : { *(.data .data.*) } :data
    .bss  : { *(COMMON) *(.bss .bss.*) } :data

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
    }
}
```

Pieces worth pointing at:

- `ENTRY(kmain)` writes the entry-point address into the ELF header. Limine reads it from there.
- `OUTPUT_FORMAT(elf64-x86-64)` forces a 64-bit ELF, regardless of the host triple.
- The three `PHDRS` are program headers, one per protection class. Limine maps each `PT_LOAD` segment with the matching permissions, so `.text` ends up read-execute, `.rodata` read-only, `.data`/`.bss` read-write. That is what makes W^X work.
- `. = 0xffffffff80000000` sets the kernel's link address. The top 2 GiB of the 64-bit address space is the conventional home for kernel code on x86_64 ("higher half"). Limine maps us there for us. This is also why we built with `-mcmodel=kernel`.
- `KEEP(...)` on the Limine request sections prevents the linker's `--gc-sections` from discarding them. Nothing in our C++ code references them by name, so without `KEEP` they would vanish and Limine would refuse to boot.
- `ALIGN(4K)` before each permission boundary makes sure permission changes happen on page boundaries, otherwise the loader would have to map a single page as both executable and read-only.
- The `/DISCARD/` block drops `.eh_frame` (we have no exceptions), `.note*`, and `.comment`. Keeps the kernel image small.

The output is `build/kernel.elf`, the actual kernel binary.

## Packaging a hybrid BIOS+UEFI ISO

We have a kernel, but UEFI does not boot raw ELF files. It boots an EFI application from a FAT volume on a recognized boot medium. We package everything into a hybrid bootable ISO that works under both UEFI and legacy BIOS.

```bash
# Fetch Limine's prebuilt bootloader (one-time)
git clone https://github.com/limine-bootloader/limine.git \
    --branch=v9.x-binary --depth=1 build/limine
make -C build/limine

# Stage the ISO tree
mkdir -p build/iso_root/boot/limine build/iso_root/EFI/BOOT
cp build/kernel.elf  build/iso_root/boot/
cp limine.conf       build/iso_root/
cp build/limine/limine-bios.sys \
   build/limine/limine-bios-cd.bin \
   build/limine/limine-uefi-cd.bin   build/iso_root/boot/limine/
cp build/limine/BOOTX64.EFI          build/iso_root/EFI/BOOT/

# Build the hybrid ISO
xorriso -as mkisofs \
    -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    build/iso_root -o build/hello-kernel.iso

# Embed the Limine BIOS bootloader stage into the ISO
./build/limine/limine bios-install build/hello-kernel.iso
```

What is going on:

- We grab Limine's prebuilt binaries instead of building Limine from source. The `v9.x-binary` branch is exactly that: a tagged binary release.
- `BOOTX64.EFI` at `/EFI/BOOT/BOOTX64.EFI` is the path UEFI looks for when no NVRAM boot entry tells it otherwise. UEFI loads it directly. No further setup needed.
- For BIOS boot, `xorriso` writes a hybrid ISO with `limine-bios-cd.bin` as the El Torito boot image, and `limine bios-install` patches the BIOS bootloader stage into the ISO so legacy BIOS firmware can find it.
- `limine.conf` lives at the ISO root and tells Limine where the kernel is (`boot():/boot/kernel.elf`) and which protocol to use.

The end result, `build/hello-kernel.iso`, boots on real hardware and in QEMU, under either firmware.

## The full boot path

Putting it all together, here is what happens from power-on to our `Hello, World!`:

```
UEFI firmware
  ↓
loads BOOTX64.EFI somewhere in memory
  ↓
relocates it as needed
  ↓
calls its EFI entry point
  ↓
Limine starts running
  ↓
reads limine.conf, loads kernel.elf, parses ELF, finds kmain
  ↓
sets up long mode, paging, higher-half mapping, fills in request responses
  ↓
jumps to kmain
  ↓
serial_init → serial_write("Hello, World!\n") → hang
```

## Prerequisites (macOS)

Everything in this project is set up around an Apple Silicon macOS host running things under QEMU.

```bash
brew install llvm xorriso qemu
```

- `llvm` provides `clang++` and `ld.lld`. The Apple-shipped clang on macOS does not target `x86_64-elf` and does not include `lld`.
- `xorriso` builds the ISO.
- `qemu` runs the ISO.

You may need to put the Homebrew `llvm` binaries on your `PATH`:

```bash
export PATH="/opt/homebrew/opt/llvm/bin:$PATH"
```

We will also need OVMF, the UEFI firmware QEMU uses. It ships with `qemu` on macOS at `/opt/homebrew/share/qemu/edk2-x86_64-code.fd` (Apple Silicon) or `/usr/local/share/qemu/edk2-x86_64-code.fd` (Intel).

Limine itself is fetched automatically by `script.sh` the first time you build.

## Build and run

Build the ISO:

```bash
./script.sh
```

Boot it in QEMU under UEFI, with COM1 wired straight to the host terminal:

```bash
qemu-system-x86_64 \
    -M q35 -m 256M \
    -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    -cdrom build/hello-kernel.iso \
    -serial stdio
```

The OVMF firmware that ships with Homebrew's QEMU is a split-format pflash image, so it has to be attached as a pflash drive. The more familiar `-bios <path>` form does not work with it and will fail with `could not load PC BIOS`.

`-serial stdio` is the bit that closes the loop: every byte we `outb` to `COM1` shows up in the terminal you ran `qemu` from. You should see:

```
Hello, World!
```

To quit QEMU, press `Ctrl-A` then `X`.

## Where to go next

This is the smallest possible kernel: it boots, prints, halts. From here, the natural next steps are setting up a GDT and IDT so we can take interrupts, walking and customizing Limine's page tables, drawing text into the framebuffer Limine handed us, and eventually carving up memory with a real allocator. Each of those is its own README.
