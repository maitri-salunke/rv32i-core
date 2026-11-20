# rv32i-core - top-level flow
#   make lint          Verilator -Wall lint of core + SoC
#   make sim           build the Verilator core testbench
#   make test-isa      riscv-tests rv32ui-p + rv32mi-p (+ Spike commit-log diff)
#   make test-random N=100 [SEED=1] [MIX=branch]   random programs, lock-step diff vs Spike
#   make cpi           Dhrystone CPI from mcycle/minstret
#   make test-soc      SoC smoke test (APB UART + APB timer interrupt)
#   make synth         Yosys + OpenSTA quick look (sky130 tt), no P&R
#   make pd            OpenLane2/LibreLane hardening (Docker), see pd/README.md
#   make clean

TOOLS       ?= $(abspath ../tools)
RISCV_TESTS ?= $(TOOLS)/src/riscv-tests
SPIKE       ?= $(TOOLS)/spike/bin/spike
PREFIX      ?= riscv64-elf-
CC          := $(PREFIX)gcc
PY          ?= python3
N           ?= 100
SEED        ?= 1
MIX         ?= default
JOBS        ?= 4

BUILD   := build
SIM     := $(BUILD)/sim/Vtb_core
SOCSIM  := $(BUILD)/soc/Vtb_soc
CORE_SRC := $(filter-out +incdir%,$(shell cat rtl/core/core.f)) rtl/core/rv32i_defs.svh
CORE_F  := -f rtl/core/core.f
SOC_SRC := rtl/soc/uart/uart_baud_gen.sv rtl/soc/uart/uart_fifo.sv rtl/soc/uart/uart_tx.sv \
           rtl/soc/uart/uart_rx.sv rtl/soc/uart/apb_uart.sv \
           rtl/soc/apb_timer.sv rtl/soc/apb_bridge.sv rtl/soc/soc_ram.sv rtl/soc/soc_top.sv

VFLAGS  := --binary --timing -j $(JOBS) -O3 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND

SW_CFLAGS := -march=rv32i_zicsr -mabi=ilp32 -O2 -ffreestanding -fno-builtin-printf \
             -fno-common -mcmodel=medany -static -nostdlib -nostartfiles \
             -Isw/common/include -Isw/common -Wl,--no-warn-rwx-segments
SW_COMMON := sw/common/crt0.S sw/common/libc.c
DHRY_RUNS ?= 2000
DHRY_CFLAGS := -DNUMBER_OF_RUNS=$(DHRY_RUNS) -std=gnu89 -Wno-implicit-int \
               -Wno-implicit-function-declaration -Wno-return-type -Wno-old-style-definition

.PHONY: all lint sim test-isa test-random cpi test-soc synth pd clean mutation

all: lint test-isa test-random cpi test-soc

lint:
	verilator --lint-only -Wall $(CORE_F) --top-module rv32i_core
	verilator --lint-only -Wall -Wno-DECLFILENAME $(CORE_F) $(SOC_SRC) --top-module soc_top
	@echo "lint: clean"

sim: $(SIM)
$(SIM): $(CORE_SRC) tb/tb_core.sv tb/rv_tracer.sv
	@mkdir -p $(BUILD)/sim
	verilator $(VFLAGS) --top-module tb_core -Mdir $(BUILD)/sim/obj -o ../Vtb_core \
	  $(CORE_F) tb/rv_tracer.sv tb/tb_core.sv

test-isa: $(SIM)
	$(PY) scripts/run_isa.py --tests $(RISCV_TESTS) --sim $(SIM) --spike $(SPIKE)
	$(PY) scripts/run_isa.py --tests $(RISCV_TESTS) --sim $(SIM) --stall-pct 30

test-random: $(SIM)
	$(PY) scripts/run_random.py --n $(N) --seed $(SEED) --sim $(SIM) --spike $(SPIKE) -j $(JOBS) --mix $(MIX)

mutation: $(SIM)
	$(PY) scripts/mutation.py $(SPIKE) 6

# ---------------------------------------------------------------- software
$(BUILD)/sw/dhrystone.elf: sw/dhrystone/*.c sw/dhrystone/*.h $(SW_COMMON) sw/common/console_sim.c
	@mkdir -p $(BUILD)/sw
	$(CC) $(SW_CFLAGS) $(DHRY_CFLAGS) -Tsw/common/link.ld $(SW_COMMON) sw/common/console_sim.c \
	  sw/dhrystone/dhrystone.c sw/dhrystone/dhrystone_main.c -lgcc -o $@

cpi: $(SIM) $(BUILD)/sw/dhrystone.elf
	$(PY) scripts/cpi.py --sim $(SIM) --elf $(BUILD)/sw/dhrystone.elf

# ---------------------------------------------------------------- SoC
$(SOCSIM): $(CORE_SRC) $(SOC_SRC) tb/tb_soc.sv
	@mkdir -p $(BUILD)/soc
	verilator $(VFLAGS) -Wno-DECLFILENAME --top-module tb_soc -Mdir $(BUILD)/soc/obj -o ../Vtb_soc \
	  $(CORE_F) $(SOC_SRC) tb/tb_soc.sv

$(BUILD)/sw/soc_test.elf: sw/soc_test/*.c sw/soc_test/*.ld $(SW_COMMON)
	@mkdir -p $(BUILD)/sw
	$(CC) $(SW_CFLAGS) -Tsw/soc_test/link_soc.ld $(SW_COMMON) sw/soc_test/soc_test.c -lgcc -o $@

test-soc: $(SOCSIM) $(BUILD)/sw/soc_test.elf
	$(PY) scripts/elf2hex.py $(BUILD)/sw/soc_test.elf $(BUILD)/sw/soc_test.hex > $(BUILD)/sw/soc_test.tohost
	$(SOCSIM) +hex=$(BUILD)/sw/soc_test.hex +tohost=$$(cat $(BUILD)/sw/soc_test.tohost) | grep -v '^- '

# ---------------------------------------------------------------- physical design
synth:
	$(MAKE) -C pd synth

pd:
	$(MAKE) -C pd pd

clean:
	rm -rf $(BUILD)
