// Consumer-owned kernel configuration. These defaults come from kernel.zig;
// change individual fields here, or override them with zig build -D flags.
// Values take effect at build time, not while the OS is running.
const default = @import("kernel/src/config_defaults.zig");

pub const heap_mib: usize = default.heap_mib;
pub const boot_stack_mib: usize = default.boot_stack_mib;
pub const max_tasks: usize = default.max_tasks;
pub const process_code_pages: usize = default.process_code_pages;
pub const user_stack_pages: usize = default.user_stack_pages;
pub const kernel_stack_pages: usize = default.kernel_stack_pages;
pub const max_syscall_write_bytes: usize = default.max_syscall_write_bytes;
pub const pit_hz: u64 = default.pit_hz;
pub const user_code_base: u64 = default.user_code_base;
pub const user_stack_top: u64 = default.user_stack_top;
pub const ata_secondary: bool = default.ata_secondary;
pub const ata_slave: bool = default.ata_slave;
pub const ata_spin_limit: u32 = default.ata_spin_limit;
