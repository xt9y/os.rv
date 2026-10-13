ZIG  ?= zig
QEMU ?= qemu-system-x86_64
BUILD := .build
ISO   := $(BUILD)/rv-os.iso
ELF   := zig-out/bin/rv-os
DISK  := $(BUILD)/disk.img

.PHONY: all init kernel compile run run-gui clean distclean
.DEFAULT_GOAL := all
all: compile

init:
	@git submodule update --init --recursive
	@test -f kernel/src/boot.zig && test -f revo/build.zig && test -f kernel/limine/Makefile || { echo 'missing submodules' >&2; exit 1; }

$(BUILD)/program.rv: $(wildcard src/*.rv) Makefile | init
	@mkdir -p $(BUILD)
	@{ for f in $$(find src -maxdepth 1 -name '*.rv' ! -name 'main.rv' | sort); do cat "$$f"; printf '\n'; done; cat src/main.rv; printf '\n'; } > "$@.tmp"
	@if cmp -s "$@.tmp" "$@"; then rm "$@.tmp"; else mv "$@.tmp" "$@"; fi

kernel: $(BUILD)/program.rv
	@$(ZIG) build -Doptimize=ReleaseSmall
	@echo "Kernel ELF: $(ELF)"

kernel/limine/limine: | init
	@$(MAKE) -C kernel/limine

compile: kernel kernel/limine/limine
	@rm -rf $(BUILD)/iso_root
	@mkdir -p $(BUILD)/iso_root/boot/limine $(BUILD)/iso_root/EFI/BOOT
	@cp $(ELF) $(BUILD)/iso_root/boot/rv-os
	@printf 'timeout: 0\n\n/rv.os\n    protocol: limine\n    path: boot():/boot/rv-os\n' > $(BUILD)/iso_root/boot/limine/limine.conf
	@cp kernel/limine/limine-bios.sys kernel/limine/limine-bios-cd.bin kernel/limine/limine-uefi-cd.bin $(BUILD)/iso_root/boot/limine/
	@cp kernel/limine/BOOTX64.EFI kernel/limine/BOOTIA32.EFI $(BUILD)/iso_root/EFI/BOOT/
	@xorriso -as mkisofs -R -r -J \
		-b boot/limine/limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		-hfsplus -apm-block-size 2048 \
		--efi-boot boot/limine/limine-uefi-cd.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		$(BUILD)/iso_root -o $(ISO)
	@./kernel/limine/limine bios-install $(ISO)
	@echo "ISO: $(ISO)"

$(DISK):
	@mkdir -p $(BUILD)
	@qemu-img create -f raw $@ 16M

run: compile $(DISK)
	@$(QEMU) -M pc -m 256M -smp 1 -cdrom $(ISO) -boot d -display none -serial stdio -monitor none -no-reboot \
		-drive file=$(DISK),format=raw,if=ide,index=0

run-gui: compile $(DISK)
	@$(QEMU) -M pc -m 256M -smp 1 -cdrom $(ISO) -boot d -vga std -serial stdio -monitor none -no-reboot \
		-drive file=$(DISK),format=raw,if=ide,index=0

# Keep the persistent disk image across ordinary clean/build cycles.
clean:
	@rm -rf $(BUILD)/iso_root $(BUILD)/program.rv $(ISO) zig-out .zig-cache

distclean: clean
	@rm -f $(DISK)
