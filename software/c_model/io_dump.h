#ifndef IO_DUMP_H
#define IO_DUMP_H

#include "tensor.h"

// Load a simple 1D space-separated or newline-separated txt into a Tensor
int load_tensor_3d(const char* filepath, Tensor3D* t);
int load_weight_4d(const char* filepath, Weight4D* w);
int load_tensor_1d(const char* filepath, Tensor1D* t);

// Dump a Tensor out to a .txt file
void dump_tensor_3d(const char* filepath, Tensor3D* t);

#endif // IO_DUMP_H
