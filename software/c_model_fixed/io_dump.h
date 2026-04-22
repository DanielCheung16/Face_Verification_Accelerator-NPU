#ifndef IO_DUMP_H
#define IO_DUMP_H

#include "tensor.h"

int load_tensor_3d(const char* filepath, Tensor3D* t);
int load_weight_4d(const char* filepath, Weight4D* w);
int load_tensor_1d_32(const char* filepath, Tensor1D_32* t);
int load_tensor_1d_16(const char* filepath, Tensor1D_16* t);

void dump_tensor_3d(const char* filepath, Tensor3D* t);

#endif
