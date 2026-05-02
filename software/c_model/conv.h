#ifndef CONV_H
#define CONV_H

#include "tensor.h"

// Basic convolution with optional bias addition.
// If bias is NULL, it's skipped.
void conv2d(
    Tensor3D* input, 
    Weight4D* weight, 
    Tensor1D* bias, 
    Tensor3D* output,
    int stride, 
    int padding);

// Depthwise convolution (in_channels == out_channels, groups == in_channels)
void depthwise_conv2d(
    Tensor3D* input, 
    Weight4D* weight, 
    Tensor1D* bias, 
    Tensor3D* output,
    int stride, 
    int padding);

#endif // CONV_H
