#include <stdlib.h>
#include <stdio.h>
#include "tensor.h"

Tensor3D* create_tensor_3d(int c, int h, int w) {
    Tensor3D* t = (Tensor3D*)malloc(sizeof(Tensor3D));
    t->channels = c;
    t->height = h;
    t->width = w;
    t->data = (int16_t*)calloc(c * h * w, sizeof(int16_t));
    return t;
}

void free_tensor_3d(Tensor3D* t) {
    if (t) {
        if (t->data) free(t->data);
        free(t);
    }
}

void add_tensor_inplace(Tensor3D* dest, Tensor3D* src) {
    if (dest->channels != src->channels || dest->height != src->height || dest->width != src->width) {
        printf("Error: Tensor dimension mismatch in addition.\n");
        return;
    }
    int total = dest->channels * dest->height * dest->width;
    for (int i = 0; i < total; i++) {
        dest->data[i] += src->data[i];
    }
}

Weight4D* create_weight_4d(int cout, int cin, int kh, int kw) {
    Weight4D* w = (Weight4D*)malloc(sizeof(Weight4D));
    w->out_channels = cout;
    w->in_channels = cin;
    w->kernel_h = kh;
    w->kernel_w = kw;
    w->data = (int16_t*)calloc(cout * cin * kh * kw, sizeof(int16_t));
    return w;
}

void free_weight_4d(Weight4D* w) {
    if (w) {
        if (w->data) free(w->data);
        free(w);
    }
}

Tensor1D_32* create_tensor_1d_32(int size) {
    Tensor1D_32* t = (Tensor1D_32*)malloc(sizeof(Tensor1D_32));
    t->size = size;
    t->data = (int32_t*)calloc(size, sizeof(int32_t));
    return t;
}

void free_tensor_1d_32(Tensor1D_32* t) {
    if (t) {
        if (t->data) free(t->data);
        free(t);
    }
}

Tensor1D_16* create_tensor_1d_16(int size) {
    Tensor1D_16* t = (Tensor1D_16*)malloc(sizeof(Tensor1D_16));
    t->size = size;
    t->data = (int16_t*)calloc(size, sizeof(int16_t));
    return t;
}

void free_tensor_1d_16(Tensor1D_16* t) {
    if (t) {
        if (t->data) free(t->data);
        free(t);
    }
}
