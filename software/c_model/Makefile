CC = gcc
CFLAGS = -Wall -O2

SRCS = main.c tensor.c io_dump.c conv.c activation.c
OBJS = $(addprefix build/, $(SRCS:.c=.o))
TARGET_GOLDEN = c_golden_model
TARGET_INFER = c_inference_model

all: build_dir $(TARGET_GOLDEN) $(TARGET_INFER)

build_dir:
	mkdir -p build

$(TARGET_GOLDEN): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

build/inference_main.o: inference_main.c
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET_INFER): build/inference_main.o build/tensor.o build/io_dump.o build/conv.o build/activation.o
	$(CC) $(CFLAGS) -o $@ $^

build/%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build $(TARGET_GOLDEN) $(TARGET_INFER)
