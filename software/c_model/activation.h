#ifndef ACTIVATION_H
#define ACTIVATION_H

#include "tensor.h"

// In-place Parametric ReLU
void prelu_inplace(Tensor3D* t, Tensor1D* prelu_weights);

// In-place standard ReLU (if needed)
void relu_inplace(Tensor3D* t);

#endif // ACTIVATION_H
