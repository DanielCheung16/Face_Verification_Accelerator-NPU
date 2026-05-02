#ifndef ACTIVATION_H
#define ACTIVATION_H

#include "tensor.h"

void prelu_inplace(Tensor3D* t, Tensor1D_16* prelu_w);

#endif
