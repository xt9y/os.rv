const std = @import("std");

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
