const std = @import("std");
const revo = @import("revo");
const k = @import("kernel");

const program = @embedFile("rv_program");
const module_archive = @embedFile("rv_modules");
const HostResult = revo.baselib.host.HostResult;
const HostType = revo.baselib.host.ParamType;
var vm_ptr: ?*revo.VM = null;
// Buffer output until Revo returns from its VM callback. This avoids
// recursively entering the interpreter from serial_puts() or print().
var pending: [65536]u8 = undefined;
var pending_len: usize = 0;


const EmbeddedModule = struct {
    path: []const u8,
    source: []const u8,
};

// Read the byte-counted source archive made by build.zig.
fn lookupModule(requested: []const u8, import_dir: ?[]const u8) ?EmbeddedModule {
    if (!std.mem.startsWith(u8, requested, "./")) return null;
    const local = requested[2..];
    if (local.len == 0 or local[0] == '/' or std.mem.find(u8, local, "..") != null or
        std.mem.findScalar(u8, local, '\\') != null) return null;

    const dir = import_dir orelse ".";
    if (std.mem.find(u8, dir, "..") != null or std.mem.startsWith(u8, dir, "/")) return null;

    var name_buf: [512]u8 = undefined;
    const wanted = if (std.mem.eql(u8, dir, "."))
        local
    else
        std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ dir, local }) catch return null;

    var cursor: usize = 0;
    while (cursor < module_archive.len) {
        const path_end = cursor + (std.mem.findScalar(u8, module_archive[cursor..], '\n') orelse return null);
        const path = module_archive[cursor..path_end];
        cursor = path_end + 1;
        const size_end = cursor + (std.mem.findScalar(u8, module_archive[cursor..], '\n') orelse return null);
        const size = std.fmt.parseInt(usize, module_archive[cursor..size_end], 10) catch return null;
        cursor = size_end + 1;
        if (size > module_archive.len - cursor) return null;
        const source = module_archive[cursor .. cursor + size];
        cursor += size;

        const matched = std.mem.eql(u8, path, wanted) or
            (path.len == wanted.len + 3 and std.mem.eql(u8, path[0..wanted.len], wanted) and
                std.mem.eql(u8, path[wanted.len..], ".rv"));
        if (matched) return .{ .path = path, .source = source };
    }
    return null;
}

// Override the host-filesystem import function for the freestanding VM.
// Imported module export tables are rooted through Revo's import cache.
fn hostImport(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const sid = args[0].asString() orelse return HostResult.other("import expects a string");
    const module = lookupModule(vm.stringValue(sid), vm.import_dir) orelse
        return HostResult.other("embedded Revo module not found");
    if (vm.import_cache.get(module.path)) |cached| return HostResult.data(cached.result);
    for (vm.loading_stack.items) |loading| {
        if (std.mem.eql(u8, loading, module.path)) return HostResult.other("cyclic module import");
    }

    const loading_key = try vm.runtime.alloc.dupe(u8, module.path);
    try vm.loading_stack.append(vm.runtime.alloc, loading_key);
    defer {
        _ = vm.loading_stack.pop();
        vm.runtime.alloc.free(loading_key);
    }

    const source: revo.lang.Source = .{ .name = module.path, .text = module.source };
    const built = try revo.lang.build(vm, source, .{ .module_scope = true });
    const artifact = switch (built) {
        .ok => |compiled| compiled,
        .err => |failure| {
            var writer = k.io.SinkWriter.init();
            revo.lang.renderError(vm.runtime.alloc, &writer.interface, source, failure, .{}) catch {};
            puts("\n");
            return HostResult.other("module compilation failed");
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);

    const outcome = try revo.run.runBytecodeReport(vm, module.path, artifact.instructions);
    if (outcome == .err) return HostResult.other("module execution failed");
    const value = vm.currentFiber().result;

    const key = try vm.runtime.alloc.dupe(u8, module.path);
    errdefer vm.runtime.alloc.free(key);
    try vm.import_cache.put(key, .{ .result = value, .stamp = .{ .mtime = 0, .size = module.source.len } });
    return HostResult.data(value);
}

fn puts(bytes: []const u8) void {
    k.serial.write(bytes);
    const count = @min(bytes.len, pending.len - pending_len);
    @memcpy(pending[pending_len .. pending_len + count], bytes[0..count]);
    pending_len += count;
}

fn flushTerminal() void {
    const vm = vm_ptr orelse return;
    if (pending_len == 0) return;
    const callback = vm.getGlobal("terminal_output") orelse return;
    if (callback.asFunction() == null) return;
    const data = vm.ownValueString(pending[0..pending_len]) catch return;
    pending_len = 0;
    _ = vm.callFunctionParts(callback, null, &[_]revo.Value{data}, null) catch {
        k.serial.write("Revo: terminal_output failed\n");
    };
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


// Strictly validate floating-point Revo integers at the native boundary.
fn uintArg(args: []const revo.Value, index: usize) ?u64 {
    const value = args[index].asNumOpt() orelse return null;
    if (!std.math.isFinite(value) or value < 0 or value > 4_503_599_627_370_496.0 or @floor(value) != value) return null;
    return @intFromFloat(value);
}
fn number(value: u64) HostResult {
    return HostResult.data(revo.Value.new.num(@as(f64, @floatFromInt(value))));
}
fn boolean(value: bool) HostResult {
    return HostResult._bool(value);
}
fn hexNibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}
fn decodeHex(hex: []const u8, buf: []u8) ?usize {
    if (hex.len % 2 != 0 or hex.len / 2 > buf.len) return null;
    for (0..hex.len / 2) |i| {
        const hi = hexNibble(hex[i * 2]) orelse return null;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return null;
        buf[i] = (hi << 4) | lo;
    }
    return hex.len / 2;
}
fn register(vm: *revo.VM, comptime name: []const u8, comptime types: []const HostType, impl: revo.baselib.host.HostFn) !void {
    const f = try vm.installHost(name, revo.baselib.host.define(types, impl));
    try vm.registerGlobal(name, f);
}

fn hostTime(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return number(k.timer.millis());
}
fn hostDiskSectors(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return number(k.ata.sectorCount());
}
fn hostDiskRead(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const lba = uintArg(args, 0) orelse return HostResult.other("invalid LBA");
    if (lba >= k.ata.sectorCount() or lba >= (@as(u64, 1) << 28)) return HostResult.other("sector out of range");
    var bytes: [k.ata.SECTOR]u8 = undefined;
    if (!k.ata.read(@intCast(lba), &bytes)) return HostResult.other("disk read failed");
    const digits = "0123456789abcdef";
    var hex: [k.ata.SECTOR * 2]u8 = undefined;
    for (bytes, 0..) |b, i| {
        hex[i * 2] = digits[b >> 4];
        hex[i * 2 + 1] = digits[b & 15];
    }
    return HostResult.data(try vm.ownValueString(&hex));
}
fn hostDiskWrite(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const lba = uintArg(args, 0) orelse return boolean(false);
    if (lba >= k.ata.sectorCount() or lba >= (@as(u64, 1) << 28)) return boolean(false);
    const sid = args[1].asString() orelse return boolean(false);
    const hex = vm.stringValue(sid);
    var bytes: [k.ata.SECTOR]u8 = undefined;
    if ((decodeHex(hex, &bytes) orelse return boolean(false)) != bytes.len) return boolean(false);
    return boolean(k.ata.write(@intCast(lba), &bytes));
}
fn hostFbWidth(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return number(if (k.framebuffer.info()) |fb| fb.width else 0);
}
fn hostFbHeight(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return number(if (k.framebuffer.info()) |fb| fb.height else 0);
}
fn hostFbPixel(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const x = uintArg(args, 0) orelse return boolean(false);
    const y = uintArg(args, 1) orelse return boolean(false);
    const color = uintArg(args, 2) orelse return boolean(false);
    if (color > 0xffffff) return boolean(false);
    return boolean(k.framebuffer.pixel(x, y, @intCast(color)));
}
fn hostFbClear(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const color = uintArg(args, 0) orelse return boolean(false);
    if (color > 0xffffff) return boolean(false);
    return boolean(k.framebuffer.clear(@intCast(color)));
}
fn hostFbRect(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const x = uintArg(args, 0) orelse return boolean(false);
    const y = uintArg(args, 1) orelse return boolean(false);
    const width = uintArg(args, 2) orelse return boolean(false);
    const height = uintArg(args, 3) orelse return boolean(false);
    const color = uintArg(args, 4) orelse return boolean(false);
    const fb = k.framebuffer.info() orelse return boolean(false);
    if (color > 0xffffff or x >= fb.width or y >= fb.height) return boolean(false);
    const w = @min(width, fb.width - x);
    const h = @min(height, fb.height - y);
    for (0..@intCast(h)) |dy| {
        for (0..@intCast(w)) |dx| {
            _ = k.framebuffer.pixel(x + dx, y + dy, @intCast(color));
        }
    }
    return boolean(true);
}

// Revo owns the font data; Zig only copies the supplied 5x7 bitmap.
fn hostFbGlyph(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const x = uintArg(args, 0) orelse return boolean(false);
    const y = uintArg(args, 1) orelse return boolean(false);
    const sid = args[2].asString() orelse return boolean(false);
    const glyph = vm.stringValue(sid);
    const fg = uintArg(args, 3) orelse return boolean(false);
    const bg = uintArg(args, 4) orelse return boolean(false);
    if (glyph.len != 14 or fg > 0xffffff or bg > 0xffffff) return boolean(false);
    for (0..7) |row| {
        const hi = hexNibble(glyph[row * 2]) orelse return boolean(false);
        const lo = hexNibble(glyph[row * 2 + 1]) orelse return boolean(false);
        const bits = (hi << 4) | lo;
        for (0..5) |col| {
            const on = (bits & (@as(u8, 1) << @as(u3, @intCast(4 - col)))) != 0;
            const color: u32 = @intCast(if (on) fg else bg);
            for (0..2) |dy| {
                for (0..2) |dx| {
                    _ = k.framebuffer.pixel(x + col * 2 + dx, y + row * 2 + dy, color);
                }
            }
        }
    }
    return boolean(true);
}

fn hostProcCount(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return number(k.tasks.count());
}
fn hostProcState(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const pid = uintArg(args, 0) orelse return number(0);
    return number(k.tasks.state(pid));
}
fn hostProcSpawn(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const sid = args[0].asString() orelse return HostResult.other("expected hex string");
    const hex = vm.stringValue(sid);
    if (hex.len % 2 != 0 or hex.len / 2 > k.tasks.CODE_SIZE)
        return HostResult.other("invalid or oversized process image");
    // Allocate exactly the supplied image size instead of reserving a fixed
    // 4 KiB (or consumer-selected maximum) on the kernel call stack.
    const code = try vm.runtime.alloc.alloc(u8, hex.len / 2);
    defer vm.runtime.alloc.free(code);
    const len = decodeHex(hex, code) orelse return HostResult.other("invalid hex process image");
    const pid = k.tasks.spawn(code[0..len]) orelse return HostResult.other("cannot create process");
    return number(pid);
}

pub fn boot(alloc: std.mem.Allocator) void {
    k.io.setSink(puts);
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

    register(vm, "import", &.{.string}, hostImport) catch return puts("Revo: module registration failed\n");
    register(vm, "serial_puts", &.{.string}, hostPuts) catch return puts("Revo: host registration failed\n");
    register(vm, "time_ms", &.{}, hostTime) catch return puts("Revo: time registration failed\n");
    register(vm, "disk_sectors", &.{}, hostDiskSectors) catch return puts("Revo: disk registration failed\n");
    register(vm, "disk_read_hex", &.{.number}, hostDiskRead) catch return puts("Revo: disk registration failed\n");
    register(vm, "disk_write_hex", &.{.number, .string}, hostDiskWrite) catch return puts("Revo: disk registration failed\n");
    register(vm, "fb_width", &.{}, hostFbWidth) catch return puts("Revo: framebuffer registration failed\n");
    register(vm, "fb_height", &.{}, hostFbHeight) catch return puts("Revo: framebuffer registration failed\n");
    register(vm, "fb_pixel", &.{.number, .number, .number}, hostFbPixel) catch return puts("Revo: framebuffer registration failed\n");
    register(vm, "fb_clear", &.{.number}, hostFbClear) catch return puts("Revo: framebuffer registration failed\n");
    register(vm, "fb_rect", &.{.number, .number, .number, .number, .number}, hostFbRect) catch return puts("Revo: framebuffer registration failed\n");
    register(vm, "fb_glyph", &.{.number, .number, .string, .number, .number}, hostFbGlyph) catch return puts("Revo: framebuffer registration failed\n");
    register(vm, "proc_count", &.{}, hostProcCount) catch return puts("Revo: process registration failed\n");
    register(vm, "proc_state", &.{.number}, hostProcState) catch return puts("Revo: process registration failed\n");
    register(vm, "proc_spawn_hex", &.{.string}, hostProcSpawn) catch return puts("Revo: process registration failed\n");

    const build_result = revo.lang.build(vm, .{ .name = "main.rv", .text = program }, .{}) catch {
        puts("Revo: compilation threw\n");
        return;
    };
    const artifact = switch (build_result) {
        .ok => |compiled| compiled,
        .err => |failure| {
            puts("Revo: compilation failed\n");
            var writer = k.io.SinkWriter.init();
            revo.lang.renderError(alloc, &writer.interface, .{ .name = "main.rv", .text = program }, failure, .{}) catch {};
            puts("\n");
            return;
        },
    };
    vm.setProgramDebugInfo(artifact.spans, "", "main.rv") catch {
        puts("Revo: debug symbols failed\n");
        return;
    };
    const result = revo.run.runBytecodeReport(vm, "main.rv", artifact.instructions) catch {
        puts("Revo: execution threw\n");
        return;
    };
    switch (result) {
        .ok => {
            vm_ptr = vm;
            flushTerminal();
        },
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
    flushTerminal();
}
