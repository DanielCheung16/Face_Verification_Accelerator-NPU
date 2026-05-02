#ifndef CONV_H
#define CONV_H

#include "tensor.h"

void conv2d(Tensor3D* input, Weight4D* weight, Tensor1D_32* bias, Tensor3D* output, int stride, int padding);
void depthwise_conv2d(Tensor3D* input, Weight4D* weight, Tensor1D_32* bias, Tensor3D* output, int stride, int padding);

#endif
