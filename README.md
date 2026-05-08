# hello-kernel

This project is a `Hello World` project aimed to explain how a kernel works and how to build your own. It's built in contrast the the `std::cout << "Hello\n";` line you would find in your typical C++ hello world project where stdout may ultimately be connected to `/dev/ttyS0`.

Before we started digging into any of the kernel code, I think it's important to explain the end-to-end flow of a simple `std::cout`.

std::cout << "Hello\n"; places or references the bytes "Hello\n" in user-space memory, usually through the C++ stream buffering system. When the stream is flushed, the C/C++ runtime makes a write syscall, passing Linux a file descriptor, usually 1 for stdout, plus a pointer to the user-space buffer and the number of bytes to write. If fd 1 is connected to /dev/ttyS0, Linux routes the write through the TTY/serial subsystem to the serial driver. For a classic x86 COM1 UART, the serial driver eventually writes bytes to the UART’s I/O ports, typically using an outb-style instruction to the base port 0x3F8.

We can see that there are many layers before it ultimately ends up on the I/O port which is the COM 1 base port. This is needed because of the std::cout being execute in userspace which doesn't have access to privileged I/O instructions.

We'll implement this hello world by also writing `Hello` to the I/O port, after initializing the serial port, which requires us to execute the `outb` instruction directly. That becomes the simple part, the bulk of the work becomes about "What and how do we build a kernel to do this".

The next, thing that we need to understand is how a kernel is started, ultimately the `./hello_world` of a kernel. When the CPU starts or resets, it begins executing firmware code from a fixed reset location. On modern PCs, that firmware is usually UEFI. The UEFI firmware initializes the system, discovers bootable devices, and loads a bootloader as an EFI application. In our case, that bootloader is Limine.

Limine then reads its configuration file, loads the kernel file specified in that config, interprets the kernel’s executable format, and finds the kernel’s entry point. After preparing the required boot information for the kernel, Limine transfers control to the kernel’s entry point.


There's a bit more to explain but let's get started.

We start with our `kmain` function in our `main.cpp` file.

```main.cpp
extern "C" [[noreturn]] void kmain() {
    serial_init();
    serial_write("Hello, World!\n");
    hang();
}
````

This is the entry point the the bootloader will call, assuming our linker setup marks it as the kernel entry point.

We can compile this file using `clang++` with a few flags which will produce a `main.o` file for us.

This file doesn't mean anything to the CPU as a complete program yet, it's called an object file which contains machine code along with symbols, sections, and relocation information.

We then link the object files into an ELF file. The .o files already contain machine-code instructions for the CPU architecture we compiled for, but they are not complete executable images yet. They may still reference symbols whose final addresses are unknown. The linker combines all object files, resolves those references, applies relocations, arranges the code and data into the final memory layout, and writes an ELF file containing the final kernel image, load information, and the kernel entry point.

Now we have our kernel, the `.elf` file. The last step is to package everything into a `.iso` which will include the `Limine EFI bootloader`, `Limine config`, and our `.elf` kernel.

When this is loaded onto the boot device, it will then start at the process

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
loads the kernel ELF and jumps to its entry point
  ↓
Kernel
```

