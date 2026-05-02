#ifndef TENSOR_H
#define TENSOR_H

#include <stdint.h>

#define Q_FRAC_BITS 10

typedef struct {
    int channels;
    int height;
    int width;
    int16_t* data;
} Tensor3D;

typedef struct {
    int out_channels;
    int in_channels;
    int kernel_h;
    int kernel_w;
    int16_t* data;
} Weight4D;

typedef struct {
    int size;
    int32_t* data;
} Tensor1D_32;

typedef struct {
    int size;
    int16_t* data;
} Tensor1D_16;

Tensor3D* create_tensor_3d(int c, int h, int w);
void free_tensor_3d(Tensor3D* t);
void add_tensor_inplace(Tensor3D* dest, Tensor3D* src);

Weight4D* create_weight_4d(int cout, int cin, int kh, int kw);
void free_weight_4d(Weight4D* w);

Tensor1D_32* create_tensor_1d_32(int size);
void free_tensor_1d_32(Tensor1D_32* t);

Tensor1D_16* create_tensor_1d_16(int size);
void free_tensor_1d_16(Tensor1D_16* t);

#endif
