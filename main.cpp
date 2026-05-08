// Freestanding kernel entry point. No libc, no C++ runtime, no exceptions, no RTTI.
// The bootloader (Limine) loads this binary and jumps directly to kmain().

#include <stdint.h>
#include <stddef.h>

namespace {

// ---------------------------------------------------------------------------
// Serial port (COM1 / 16550 UART)
// ---------------------------------------------------------------------------
// We use the legacy COM1 port for output. QEMU exposes it and can pipe its
// bytes straight to the host terminal via `-serial stdio`. This is the most
// reliable debug channel before we have a framebuffer or a real console.
constexpr uint16_t COM1 = 0x3F8;

// x86 talks to legacy devices through a separate I/O address space, not memory.
// `outb` and `inb` are the only way to reach those ports, and they have no
// C equivalent, so we drop to inline assembly. The "a" constraint pins the
// value to the AL register, which is what the `outb`/`inb` instructions use.
inline void outb(uint16_t port, uint8_t val) {
    asm volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

inline uint8_t inb(uint16_t port) {
    uint8_t ret;
    asm volatile ("inb %1, %0" : "=a"(ret) : "Nd"(port));
    return ret;
}

// Configure COM1 for 38400 baud, 8 data bits, no parity, 1 stop bit (8N1).
// The magic numbers are register offsets and bit patterns from the 16550 spec.
// We do this once at boot; after this the port is ready for byte-at-a-time output.
void serial_init() {
    outb(COM1 + 1, 0x00); // IER: disable all UART interrupts (we poll instead)
    outb(COM1 + 3, 0x80); // LCR: set DLAB so the next two writes set the baud divisor
    outb(COM1 + 0, 0x03); // DLL: divisor low byte  -> 115200 / 3 = 38400 baud
    outb(COM1 + 1, 0x00); // DLM: divisor high byte
    outb(COM1 + 3, 0x03); // LCR: clear DLAB, set 8 bits / no parity / 1 stop bit
    outb(COM1 + 2, 0xC7); // FCR: enable FIFO, clear RX/TX queues, 14-byte trigger
    outb(COM1 + 4, 0x0B); // MCR: assert DTR + RTS, enable OUT2 (needed for IRQs later)
}

// Send one byte, busy-waiting until the transmitter is ready.
// Bit 5 of the Line Status Register (offset 5) is "Transmit Holding Register Empty".
// Polling is fine here because we have no scheduler yet; nothing else can run.
void serial_putc(char c) {
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, static_cast<uint8_t>(c));
}

// Walk a null-terminated string, byte by byte. No formatting, no length checks.
// This is the kernel's entire "stdout" for now.
void serial_write(const char* s) {
    for (; *s; ++s) serial_putc(*s);
}

// ---------------------------------------------------------------------------
// Halt
// ---------------------------------------------------------------------------
// `cli` masks maskable interrupts, `hlt` parks the CPU until the next one.
// With interrupts disabled, `hlt` effectively sleeps forever and the CPU
// draws minimal power. Wrapped in a loop because spurious wake-ups (NMIs,
// SMIs) can resume execution past a single `hlt`.
[[noreturn]] void hang() {
    for (;;) {
        asm volatile ("cli; hlt");
    }
}

} // namespace

// ---------------------------------------------------------------------------
// Kernel entry point
// ---------------------------------------------------------------------------
// Limine looks up this symbol by name and jumps to it after setting up long
// mode, paging, and the higher-half mapping. `extern "C"` prevents C++ name
// mangling so the symbol is exactly `kmain`. This function must never return:
// there is no caller to return to, and the stack above us is bootloader scratch.
extern "C" [[noreturn]] void kmain() {
    serial_init();
    serial_write("Hello, World!\n");
    hang();
}
