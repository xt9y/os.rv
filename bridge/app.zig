const std = @import("std");
const revo = @import("revo");
const k = @import("kernel");

const program = @embedFile("rv_program");
const HostResult = revo.baselib.host.HostResult;
const HostType = revo.baselib.host.ParamType;
var vm_ptr: ?*revo.VM = null;

fn puts(bytes: []const u8) void {
    k.write(bytes);
}

fn hostPuts(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const sid = args[0].asString() orelse return HostResult.other("serial_puts expects a string");
    puts(vm.stringValue(sid));
    return HostResult.data(revo.Value.new.nil());
}

fn renderFailure(vm: *revo.VM, failure: anytype) void {
    var writer = k.io.SinkWriter.init();
    failure.render(vm.runtime.alloc, &writer.interface, program, false) catch {};
    puts("\n");
}

pub fn boot(alloc: std.mem.Allocator) void {
    const vm = alloc.create(revo.VM) catch {
        puts("Revo: VM allocation failed\n");
        return;
    };
    vm.* = revo.VM.init(.{
        .alloc = alloc,
        .io = k.io.serial_io,
        .argv = &.{},
        .diag_alloc = alloc,
    }) catch {
        puts("Revo: VM initialization failed\n");
        return;
    };

    const define = revo.baselib.host.define;
    const putsfn = vm.installHost("serial_puts", define(&[_]HostType{.string}, hostPuts)) catch {
        puts("Revo: host registration failed\n");
        return;
    };
    vm.registerGlobal("serial_puts", putsfn) catch {
        puts("Revo: host registration failed\n");
        return;
    };

    const build_result = revo.lang.build(vm, .{ .name = "os.rv", .text = program }, .{}) catch {
        puts("Revo: compilation threw\n");
        return;
    };
    const artifact = switch (build_result) {
        .ok => |compiled| compiled,
        .err => |failure| {
            puts("Revo: compilation failed\n");
            var writer = k.io.SinkWriter.init();
            revo.lang.renderError(alloc, &writer.interface, .{ .name = "os.rv", .text = program }, failure, .{}) catch {};
            puts("\n");
            return;
        },
    };
    vm.setProgramDebugInfo(artifact.spans, "", "os.rv") catch {
        puts("Revo: debug symbols failed\n");
        return;
    };
    const result = revo.run.runBytecodeReport(vm, "os.rv", artifact.instructions) catch {
        puts("Revo: execution threw\n");
        return;
    };
    switch (result) {
        .ok => vm_ptr = vm,
        .err => |failure| {
            puts("Revo: runtime error\n");
            renderFailure(vm, failure);
        },
    }
}

pub fn onInput(byte: u8) void {
    const vm = vm_ptr orelse return;
    const callback = vm.getGlobal("on_input") orelse return;
    if (callback.asFunction() == null) return;

    const normalized: u8 = switch (byte) {
        13 => 10,    // Enter
        127 => 8,    // Backspace (macOS sends DEL)
        else => byte,
    };
    if (normalized < 32 and normalized != 8 and normalized != 10) return;
    const ch = [_]u8{normalized};
    const value = vm.ownValueString(&ch) catch return;
    _ = vm.callFunctionParts(callback, null, &[_]revo.Value{value}, null) catch |err| {
        puts("Revo: on_input error: ");
        puts(@errorName(err));
        puts("\n");
    };
}
