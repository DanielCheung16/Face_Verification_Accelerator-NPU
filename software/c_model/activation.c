#include "activation.h"

void prelu_inplace(Tensor3D* t, Tensor1D* prelu_weights) {
    int spatial = t->height * t->width;
    for (int c = 0; c < t->channels; c++) {
        float w = prelu_weights->data[c];
        for (int i = 0; i < spatial; i++) {
            int index = c * spatial + i;
            if (t->data[index] < 0.0f) {
                t->data[index] *= w;
            }
        }
    }
}

void relu_inplace(Tensor3D* t) {
    int total = t->channels * t->height * t->width;
    for (int i = 0; i < total; i++) {
        if (t->data[i] < 0.0f) {
            t->data[i] = 0.0f;
        }
    }
}
