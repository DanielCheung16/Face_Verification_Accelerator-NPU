CC = gcc
CFLAGS = -Wall -O2

SRCS = tensor.c io_dump.c conv.c activation.c
OBJS = $(addprefix build/, $(SRCS:.c=.o))
TARGET_INFER = c_inference_model_fixed

all: build_dir $(TARGET_INFER)

build_dir:
	mkdir -p build

build/inference_main.o: inference_main.c
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET_INFER): build/inference_main.o $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

build/%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build $(TARGET_INFER)
