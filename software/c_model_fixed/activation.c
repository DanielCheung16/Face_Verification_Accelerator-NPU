#include "activation.h"

void prelu_inplace(Tensor3D* t, Tensor1D_16* prelu_w) {
    int spatial_size = t->height * t->width;
    
    for (int c = 0; c < t->channels; c++) {
        int16_t w = prelu_w->data[c];
        
        for (int i = 0; i < spatial_size; i++) {
            int idx = c * spatial_size + i;
            if (t->data[idx] < 0) {
                int32_t scaled = (int32_t)t->data[idx] * (int32_t)w;
                t->data[idx] = (int16_t)(scaled >> Q_FRAC_BITS);
            }
        }
    }
}
