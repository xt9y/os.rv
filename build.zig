const std = @import("std");
const chosen = @import("bridge/kernel.config.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
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
    app.addAnonymousImport("rv_program", .{
        .root_source_file = b.path(".build/program.rv"),
    });

    const exe = b.addExecutable(.{ .name = "rv-os", .root_module = boot });
    exe.entry = .{ .symbol_name = "_start" };
    exe.pie = false;
    exe.setLinkerScript(b.path("kernel/src/linker.ld"));
    b.installArtifact(exe);
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
