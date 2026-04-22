#include "io_dump.h"

int load_tensor_3d(const char* filepath, Tensor3D* t) {
    FILE *fp = fopen(filepath, "r");
    if (!fp) {
        printf("Error: Could not open %s\n", filepath);
        return -1;
    }
    int total = t->channels * t->height * t->width;
    for (int i = 0; i < total; i++) {
        if (fscanf(fp, "%f", &t->data[i]) != 1) {
            printf("Error: Reached EOF too early or malformed float in %s at index %d\n", filepath, i);
            fclose(fp);
            return -1;
        }
    }
    fclose(fp);
    return 0;
}

int load_weight_4d(const char* filepath, Weight4D* w) {
    FILE *fp = fopen(filepath, "r");
    if (!fp) {
        printf("Error: Could not open %s\n", filepath);
        return -1;
    }
    int total = w->out_channels * w->in_channels * w->kernel_h * w->kernel_w;
    for (int i = 0; i < total; i++) {
        if (fscanf(fp, "%f", &w->data[i]) != 1) {
            fclose(fp);
            return -1;
        }
    }
    fclose(fp);
    return 0;
}

int load_tensor_1d(const char* filepath, Tensor1D* t) {
    FILE *fp = fopen(filepath, "r");
    if (!fp) {
        printf("Error: Could not open %s\n", filepath);
        return -1;
    }
    for (int i = 0; i < t->channels; i++) {
        if (fscanf(fp, "%f", &t->data[i]) != 1) {
            fclose(fp);
            return -1;
        }
    }
    fclose(fp);
    return 0;
}

void dump_tensor_3d(const char* filepath, Tensor3D* t) {
    FILE *fp = fopen(filepath, "w");
    if (!fp) {
        printf("Error: Could not open %s for writing\n", filepath);
        return;
    }
    int total = t->channels * t->height * t->width;
    for (int i = 0; i < total; i++) {
        // Output formatting aligned with Python formatting
        fprintf(fp, "%.6f\n", t->data[i]);
    }
    fclose(fp);
}
