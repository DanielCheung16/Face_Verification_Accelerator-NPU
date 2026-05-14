CC ?= gcc
CFLAGS ?= -O2 -std=c99 -Wall -Wextra -Iinclude -Igenerated
LDFLAGS ?= -lm

MODEL_OBJS := build/qface_model.o build/qface_params.o

all: qface_compare

generated/qface_params.h generated/qface_params.c:
	python gen_qface_c.py

build:
	mkdir -p build

build/qface_model.o: src/qface_model.c include/qface_model.h generated/qface_params.h | build
	$(CC) $(CFLAGS) -c -o $@ src/qface_model.c

build/qface_params.o: generated/qface_params.c generated/qface_params.h include/qface_model.h | build
	$(CC) $(CFLAGS) -c -o $@ generated/qface_params.c

qface_compare: src/main_compare.c include/qface_model.h $(MODEL_OBJS)
	$(CC) $(CFLAGS) -o $@ src/main_compare.c $(MODEL_OBJS) $(LDFLAGS)

run: qface_compare
	./qface_compare

clean:
	rm -rf build qface_compare

.PHONY: all run clean
