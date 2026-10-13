# rv.os

A minimal Revo operating system running on an independent Zig kernel, headless over QEMU COM1 serial.

- [kernel.zig](https://github.com/xt9y/kernel.zig) is an independent native kernel submodule, based on the MIT-licensed boot/memory/serial portions of Revel.
- `revo/` is the Revo language dependency submodule.
- `bridge/app.zig` hosts the VM and exposes `serial_puts` and `on_input`.
- `src/*.rv` contains the OS. Files are concatenated in filename order, with `main.rv` last.

## macOS setup

Install Zig 0.17.0, QEMU, xorriso and make:

```sh
brew install zig qemu xorriso
git submodule update --init --recursive
make kernel
make compile
make run
```

`make run` boots a **real x86-64 freestanding kernel in QEMU** and attaches its serial device to your invoking terminal. It does not create a QEMU window. Use Ctrl+C to stop QEMU.

The macOS host terminal handles the German keyboard layout. The guest receives UTF-8 input bytes, not raw PS/2 scancodes. Initial line editing is byte-based; Unicode Backspace editing remains incomplete.

## Current boundaries

This is a first-stage experimental kernel/VM integration, not a full OS. No graphical output, native applications, task scheduler, disk filesystem or user-mode isolation are implemented. It polls COM1 with CPU interrupts disabled; more hardware services can be added to `kernel.zig` later. All CLI commands, parsing and shell policy should live in Revo.

The Zig/VM integration still needs to be validated with a full Zig 0.17 build and QEMU boot.
