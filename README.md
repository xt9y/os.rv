# rv.os

Revo operating system running on [kernel.zig](https://github.com/xt9y/kernel.zig), a standalone MIT-derived x86-64 Zig kernel.

## Setup

Zig 0.17.0, QEMU and xorriso are required.

```sh
brew install zig qemu xorriso
git submodule update --init --recursive
make compile
make run
```

`make run` connects COM1 to the launching macOS terminal without opening a GUI. `make run-gui` opens a QEMU video window **in addition** to the serial shell; it does not change keyboard handling. Host macOS translates your layout into UTF-8 before QEMU serial sees input.

The first run creates `.build/disk.img` (16 MiB, raw IDE primary master). The file persists across `make clean`, but `make distclean` deletes it **and all stored data**.

## Native capabilities exposed to Revo

The only language-dependent file is `bridge/app.zig`. Hardware and scheduling are implemented by the independent `kernel/` Git submodule.

| Revo host function | Purpose |
| --- | --- |
| `serial_puts(text)` | Write to COM1 |
| `time_ms()` | Milliseconds since PIT timer started (100 Hz resolution) |
| `disk_sectors()` | Detected IDE sector count, zero if absent |
| `disk_read_hex(lba)` | Read 512 bytes as 1024 ASCII hex characters |
| `disk_write_hex(lba, hex)` | Write one 512-byte sector from exactly 1024 hex digits |
| `fb_width()`, `fb_height()` | Framebuffer size, zero when unavailable |
| `fb_pixel(x,y,rgb)`, `fb_clear(rgb)` | Pixel/clear operations on 32-bit RGB framebuffer |
| `proc_spawn_hex(code)` | Spawn <= 4096 bytes of raw position-independent x86-64 instructions in ring 3 |
| `proc_count()`, `proc_state(pid)` | Process status |

The raw process ABI is `int 0x80`, `rax=0` exit, `rax=1` write(`rdi`=pointer, `rsi`=length), `rax=2` tick count. Code loads at `0x400000`, stack ends at `0x800000`. This is a small **experimental** ring-3 executor, not an ELF loader, a production multitasking API, or a secure sandbox. Maximum seven concurrent user programs; completed processes have their private page tables reclaimed and slots can be reused. This is not yet a full ELF loader or production sandbox.

Raw disk writes mutate the persistent image. There is no partition or filesystem protection; use a disposable image for testing. Neither framebuffers nor graphical input are required for headless serial operation.

The shell in `src/main.rv` has `help`, `echo`, `clear`, `uptime`, `disk`, `disktest`, `fb`, `fbtest`, `proctest`, `faulttest`, `ps`. **`disktest` overwrites the final 512-byte sector of the attached disk image**; use only on a disposable disk. All policies and future shell/filesystem features belong in Revo.

## Validation

CI builds the freestanding ELF and ISO then boots it in QEMU with a persistent 16 MiB IDE disk. Native IRQ/ring-3 and framebuffer rendering require additional targeted tests; compile and boot success alone do not establish complete hardware correctness.

`faulttest` intentionally runs a privileged HLT instruction in ring 3. The kernel should terminate that process without stopping the Revo shell.
