#include <stdio.h>
#include <stdlib.h>
#include "io_dump.h"

int load_tensor_3d(const char* filepath, Tensor3D* t) {
    FILE* f = fopen(filepath, "r");
    if (!f) {
        printf("Error: Could not open %s\n", filepath);
        return -1;
    }
    int total = t->channels * t->height * t->width;
    for (int i = 0; i < total; i++) {
        int val;
        if (fscanf(f, "%d", &val) != 1) break;
        t->data[i] = (int16_t)val;
    }
    fclose(f);
    return 0;
}

int load_weight_4d(const char* filepath, Weight4D* w) {
    FILE* f = fopen(filepath, "r");
    if (!f) return -1;
    int total = w->out_channels * w->in_channels * w->kernel_h * w->kernel_w;
    for (int i = 0; i < total; i++) {
        int val;
        if (fscanf(f, "%d", &val) != 1) break;
        w->data[i] = (int16_t)val;
    }
    fclose(f);
    return 0;
}

int load_tensor_1d_32(const char* filepath, Tensor1D_32* t) {
    FILE* f = fopen(filepath, "r");
    if (!f) return -1;
    for (int i = 0; i < t->size; i++) {
        int val;
        if (fscanf(f, "%d", &val) != 1) break;
        t->data[i] = (int32_t)val;
    }
    fclose(f);
    return 0;
}

int load_tensor_1d_16(const char* filepath, Tensor1D_16* t) {
    FILE* f = fopen(filepath, "r");
    if (!f) return -1;
    for (int i = 0; i < t->size; i++) {
        int val;
        if (fscanf(f, "%d", &val) != 1) break;
        t->data[i] = (int16_t)val;
    }
    fclose(f);
    return 0;
}

void dump_tensor_3d(const char* filepath, Tensor3D* t) {
    FILE* f = fopen(filepath, "w");
    if (!f) return;
    int total = t->channels * t->height * t->width;
    for (int i = 0; i < total; i++) {
        fprintf(f, "%d\n", t->data[i]);
    }
    fclose(f);
}
