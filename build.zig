const std = @import("std");
const chosen = @import("bridge/kernel.config.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Kernel optimization mode (default: ReleaseSmall)") orelse .ReleaseSmall;
    var query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const Feature = std.Target.x86.Feature;
    query.cpu_features_sub.addFeature(@backingInt(Feature.mmx));
    query.cpu_features_sub.addFeature(@backingInt(Feature.avx));
    query.cpu_features_sub.addFeature(@backingInt(Feature.avx2));
    const target = b.resolveTargetQuery(query);

    const opts: std.Build.Module.CreateOptions = .{
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
        .link_libc = false,
    };

    const kernel = b.createModule(.{
        .root_source_file = b.path("kernel/src/kernel.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
        .link_libc = false,
    });
    const boot = b.createModule(.{
        .root_source_file = b.path("kernel/src/boot.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
        .link_libc = false,
    });
    const app = b.createModule(.{
        .root_source_file = b.path("bridge/app.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
        .link_libc = false,
    });
    _ = opts;

    const revo = b.dependency("revo", .{
        .target = target,
        .optimize = optimize,
        .features = "",
    }).module("revo");

    var visited: std.AutoHashMap(*std.Build.Module, void) = .init(b.allocator);
    defer visited.deinit();
    kernelize(revo, &visited);

    // The consumer controls hardware/resource policy, the kernel implements it.
    // -Dfoo= overrides values from kernel.config.zig for this build only.
    const options = b.addOptions();
    options.addOption(usize, "heap_mib", b.option(usize, "heap-mib", "Contiguous kernel heap size (MiB)") orelse chosen.heap_mib);
    options.addOption(usize, "boot_stack_mib", b.option(usize, "boot-stack-mib", "Limine bootstrap stack (MiB)") orelse chosen.boot_stack_mib);
    options.addOption(usize, "max_tasks", b.option(usize, "max-tasks", "Total task slots including PID 0") orelse chosen.max_tasks);
    options.addOption(usize, "process_code_pages", b.option(usize, "process-code-pages", "Max user executable pages (4 KiB each)") orelse chosen.process_code_pages);
    options.addOption(usize, "user_stack_pages", b.option(usize, "user-stack-pages", "User stack pages per task") orelse chosen.user_stack_pages);
    options.addOption(usize, "kernel_stack_pages", b.option(usize, "kernel-stack-pages", "Privileged stack pages per task") orelse chosen.kernel_stack_pages);
    options.addOption(usize, "max_syscall_write_bytes", b.option(usize, "max-syscall-write-bytes", "Max user write syscall bytes") orelse chosen.max_syscall_write_bytes);
    options.addOption(u64, "pit_hz", b.option(u64, "pit-hz", "8254 PIT ticks per second") orelse chosen.pit_hz);
    options.addOption(u64, "user_code_base", b.option(u64, "user-code-base", "Raw user program virtual load address") orelse chosen.user_code_base);
    options.addOption(u64, "user_stack_top", b.option(u64, "user-stack-top", "User stack virtual high address") orelse chosen.user_stack_top);
    options.addOption(bool, "ata_secondary", b.option(bool, "ata-secondary", "Use legacy secondary ATA channel") orelse chosen.ata_secondary);
    options.addOption(bool, "ata_slave", b.option(bool, "ata-slave", "Use ATA slave rather than master") orelse chosen.ata_slave);
    options.addOption(u32, "ata_spin_limit", b.option(u32, "ata-spin-limit", "ATA polling timeout (loop iterations)") orelse chosen.ata_spin_limit);

    kernel.addImport("kernel_config", options.createModule());
    boot.addImport("kernel", kernel);
    boot.addImport("app", app);
    app.addImport("kernel", kernel);
    app.addImport("revo", revo);
    // Bundle all top-level Revo sources, with main.rv last as the entry point.
    const bundle_script =
        \\set -eu
        \\src="$1"
        \\out="$2"
        \\test -f "$src/main.rv"
        \\find "$src" -maxdepth 1 -type f -name '*.rv' ! -name 'main.rv' -print | LC_ALL=C sort | while IFS= read -r file; do
        \\    cat "$file"
        \\    printf '\n'
        \\done > "$out"
        \\cat "$src/main.rv" >> "$out"
        \\printf '\n' >> "$out"
    ;
    const bundle = b.addSystemCommand(&.{ "sh", "-c", bundle_script, "revo-bundle" });
    bundle.addDirectoryArg(b.path("src"));
    const rv_program = bundle.addOutputFileArg("program.rv");
    // Always rescan src/ so newly added .rv files cannot be missed by caching.
    bundle.stdio = .inherit;

    app.addAnonymousImport("rv_program", .{
        .root_source_file = rv_program,
    });

    const exe = b.addExecutable(.{ .name = "rv-os", .root_module = boot });
    exe.entry = .{ .symbol_name = "_start" };
    exe.pie = false;
    exe.setLinkerScript(b.path("kernel/src/linker.ld"));
    b.installArtifact(exe);

    const kernel_step = b.step("kernel", "Build and install the x86-64 kernel ELF");
    kernel_step.dependOn(b.getInstallStep());

    // Limine is an independent submodule with its own Makefile.
    const limine = b.addSystemCommand(&.{ "make", "-C", "kernel/limine" });
    limine.stdio = .inherit;

    const iso_script =
        \\set -eu
        \\elf="$1"
        \\iso="$2"
        \\root="$iso.root"
        \\trap 'rm -rf "$root"' EXIT
        \\rm -rf "$root"
        \\mkdir -p "$root/boot/limine" "$root/EFI/BOOT"
        \\cp "$elf" "$root/boot/rv-os"
        \\printf '%s\n' 'timeout: 0' '' '/rv.os' '    protocol: limine' '    path: boot():/boot/rv-os' > "$root/boot/limine/limine.conf"
        \\cp kernel/limine/limine-bios.sys kernel/limine/limine-bios-cd.bin kernel/limine/limine-uefi-cd.bin "$root/boot/limine/"
        \\cp kernel/limine/BOOTX64.EFI kernel/limine/BOOTIA32.EFI "$root/EFI/BOOT/"
        \\xorriso -as mkisofs -R -r -J \
        \\    -b boot/limine/limine-bios-cd.bin \
        \\    -no-emul-boot -boot-load-size 4 -boot-info-table \
        \\    -hfsplus -apm-block-size 2048 \
        \\    --efi-boot boot/limine/limine-uefi-cd.bin \
        \\    -efi-boot-part --efi-boot-image --protective-msdos-label \
        \\    "$root" -o "$iso"
        \\kernel/limine/limine bios-install "$iso"
    ;
    const iso = b.addSystemCommand(&.{ "sh", "-c", iso_script, "make-iso" });
    iso.step.dependOn(&limine.step);
    iso.addArtifactArg(exe);
    const iso_path = iso.addOutputFileArg("rv-os.iso");
    // Hash Limine inputs so the ISO is rebuilt if the bootloader changes.
    for ([_][]const u8{
        "kernel/limine/limine",
        "kernel/limine/limine-bios.sys",
        "kernel/limine/limine-bios-cd.bin",
        "kernel/limine/limine-uefi-cd.bin",
        "kernel/limine/BOOTX64.EFI",
        "kernel/limine/BOOTIA32.EFI",
    }) |path| iso.addFileArg(b.path(path));

    const install_iso = b.addInstallFile(iso_path, "rv-os.iso");
    const iso_step = b.step("iso", "Build a bootable Limine ISO at zig-out/rv-os.iso");
    iso_step.dependOn(&install_iso.step);

    // Keep the user's raw disk image across every build and normal clean.
    const disk = b.addSystemCommand(&.{
        "sh", "-c",
        "set -eu; mkdir -p .build; if [ ! -f .build/disk.img ]; then qemu-img create -f raw .build/disk.img 16M; fi",
        "prepare-disk",
    });
    disk.stdio = .inherit;

    const qemu = b.option([]const u8, "qemu", "QEMU executable (default: qemu-system-x86_64)") orelse "qemu-system-x86_64";
    inline for (.{ false, true }) |gui| {
        const run = b.addSystemCommand(&.{ qemu, "-M", "pc", "-m", "256M", "-smp", "1", "-cdrom" });
        run.addFileArg(iso_path);
        run.addArgs(&.{ "-boot", "d" });
        if (gui) {
            run.addArgs(&.{ "-vga", "std" });
        } else {
            run.addArgs(&.{ "-display", "none" });
        }
        run.addArgs(&.{
            "-serial", "stdio", "-monitor", "none", "-no-reboot",
            "-drive", "file=.build/disk.img,format=raw,if=ide,index=0",
        });
        run.step.dependOn(&disk.step);
        run.stdio = .inherit;

        const name = if (gui) "run-gui" else "run";
        const description = if (gui) "Boot Revo OS in QEMU with a window" else "Boot Revo OS in headless QEMU";
        const run_step = b.step(name, description);
        run_step.dependOn(&run.step);
    }
}

fn kernelize(mod: *std.Build.Module, visited: *std.AutoHashMap(*std.Build.Module, void)) void {
    if (visited.contains(mod)) return;
    visited.put(mod, {}) catch @panic("OOM building module graph");
    mod.code_model = .kernel;
    mod.red_zone = false;
    mod.single_threaded = true;
    var it = mod.import_table.iterator();
    while (it.next()) |entry| kernelize(entry.value_ptr.*, visited);
}
