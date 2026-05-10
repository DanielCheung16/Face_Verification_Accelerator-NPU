CC ?= gcc
CFLAGS ?= -O2 -std=c99 -Wall -Wextra

all: quantface_conv1x1_ref

quantface_conv1x1_ref: quantface_conv1x1_ref.c quantface_conv1x1_ref_data.h
	$(CC) $(CFLAGS) -o $@ quantface_conv1x1_ref.c

run: quantface_conv1x1_ref
	./quantface_conv1x1_ref

clean:
	rm -f quantface_conv1x1_ref

.PHONY: all run clean
