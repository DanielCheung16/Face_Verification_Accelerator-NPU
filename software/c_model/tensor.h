#ifndef TENSOR_H
#define TENSOR_H

#include <stdlib.h>
#include <stdio.h>

// Represents a 3D Activation Tensor (C, H, W). 
// Data is stored in NCHW format natively as an unrolled 1D array.
typedef struct {
    int channels;
    int height;
    int width;
    float* data;
} Tensor3D;

// Represents a 4D Weight Tensor (C_out, C_in, K_h, K_w).
typedef struct {
    int out_channels;
    int in_channels;
    int kernel_h;
    int kernel_w;
    float* data;
} Weight4D;

// Represents a 1D Bias or Channel-wise param (e.g. PReLU weight).
typedef struct {
    int channels;
    float* data;
} Tensor1D;

Tensor3D* create_tensor_3d(int c, int h, int w);
void free_tensor_3d(Tensor3D* t);
void add_tensor_inplace(Tensor3D* dest, Tensor3D* src);

Weight4D* create_weight_4d(int cout, int cin, int kh, int kw);
void free_weight_4d(Weight4D* w);

Tensor1D* create_tensor_1d(int c);
void free_tensor_1d(Tensor1D* t);

#endif // TENSOR_H
