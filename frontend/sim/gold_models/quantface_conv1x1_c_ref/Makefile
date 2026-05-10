CC ?= gcc
CFLAGS ?= -O2 -std=c99 -Wall -Wextra

all: quantface_conv1x1_ref dump_sram_hex

quantface_conv1x1_ref: quantface_conv1x1_ref.c quantface_conv1x1_ref_data.h
	$(CC) $(CFLAGS) -o $@ quantface_conv1x1_ref.c

dump_sram_hex: dump_sram_hex.c quantface_conv1x1_ref_data.h
	$(CC) $(CFLAGS) -o $@ dump_sram_hex.c

run: quantface_conv1x1_ref
	./quantface_conv1x1_ref

dump: dump_sram_hex
	./dump_sram_hex out

clean:
	rm -f quantface_conv1x1_ref dump_sram_hex

.PHONY: all run dump clean
