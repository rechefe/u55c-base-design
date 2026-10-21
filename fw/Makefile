# Firmware build for the U55C PicoRV32 (RV32IMC).
#   make            -> build/<APP>.elf/.bin/.hex  (APP defaults to demo)
#   make APP=foo    -> builds apps/foo/*.c
#   make toolchain  -> downloads the xPack RISC-V GCC into ../tools/
FW_DIR     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TOOLS      := $(abspath $(FW_DIR)/../tools)
XPACK_VER  := 14.2.0-3
XPACK_DIR  := $(TOOLS)/xpack-riscv-none-elf-gcc-$(XPACK_VER)
XPACK_URL  := https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$(XPACK_VER)/xpack-riscv-none-elf-gcc-$(XPACK_VER)-linux-x64.tar.gz
CROSS      ?= $(XPACK_DIR)/bin/riscv-none-elf-

APP        ?= demo
BUILD      := build
CFLAGS     := -march=rv32imc -mabi=ilp32 -Os -g -Wall -Wextra -ffreestanding \
              -fno-builtin -ffunction-sections -fdata-sections -Ilib -std=gnu11
LDFLAGS    := -march=rv32imc -mabi=ilp32 -nostdlib -nostartfiles -T lib/link.ld \
              -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-Map=$(BUILD)/$(APP).map
LIB_SRC    := lib/start.S lib/u55c.c lib/printf.c
APP_SRC    := $(wildcard apps/$(APP)/*.c)

all: $(BUILD)/$(APP).bin $(BUILD)/$(APP).hex

$(BUILD)/$(APP).elf: $(LIB_SRC) $(APP_SRC) lib/*.h lib/link.ld | $(CROSS)gcc
	@mkdir -p $(BUILD)
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -o $@ $(LIB_SRC) $(APP_SRC) -lgcc
	$(CROSS)size $@

$(BUILD)/$(APP).bin: $(BUILD)/$(APP).elf
	$(CROSS)objcopy -O binary $< $@

# One 32-bit little-endian word per line, for $readmemh (bitstream RAM init).
$(BUILD)/$(APP).hex: $(BUILD)/$(APP).bin
	python3 -I $(FW_DIR)/bin2hex.py $< $@

$(BUILD)/$(APP).lst: $(BUILD)/$(APP).elf
	$(CROSS)objdump -d -S $< > $@

toolchain: $(CROSS)gcc
$(CROSS)gcc:
	@mkdir -p $(TOOLS)
	curl -fL --retry 3 -o $(TOOLS)/xpack.tar.gz $(XPACK_URL)
	tar -xzf $(TOOLS)/xpack.tar.gz -C $(TOOLS)
	rm -f $(TOOLS)/xpack.tar.gz

clean:
	rm -rf $(BUILD)

.PHONY: all toolchain clean
