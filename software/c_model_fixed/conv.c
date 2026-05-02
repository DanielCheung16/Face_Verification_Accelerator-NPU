#include "conv.h"

static inline int16_t clamp_to_int16(int32_t val) {
    if (val > 32767) return 32767;
    if (val < -32768) return -32768;
    return (int16_t)val;
}

void conv2d(Tensor3D* input, Weight4D* weight, Tensor1D_32* bias, Tensor3D* output, int stride, int padding) {
    int out_h = output->height;
    int out_w = output->width;
    
    for (int oc = 0; oc < weight->out_channels; oc++) {
        for (int oh = 0; oh < out_h; oh++) {
            for (int ow = 0; ow < out_w; ow++) {
                
                int32_t sum = bias ? bias->data[oc] : 0;
                
                for (int ic = 0; ic < weight->in_channels; ic++) {
                    for (int kh = 0; kh < weight->kernel_h; kh++) {
                        for (int kw = 0; kw < weight->kernel_w; kw++) {
                            
                            int ih = oh * stride - padding + kh;
                            int iw = ow * stride - padding + kw;
                            
                            if (ih >= 0 && ih < input->height && iw >= 0 && iw < input->width) {
                                int in_idx = ic * (input->height * input->width) + ih * input->width + iw;
                                int w_idx = oc * (weight->in_channels * weight->kernel_h * weight->kernel_w) + 
                                            ic * (weight->kernel_h * weight->kernel_w) + 
                                            kh * weight->kernel_w + kw;
                                
                                sum += (int32_t)input->data[in_idx] * (int32_t)weight->data[w_idx];
                            }
                        }
                    }
                }
                
                int out_idx = oc * (out_h * out_w) + oh * out_w + ow;
                output->data[out_idx] = clamp_to_int16(sum >> Q_FRAC_BITS);
            }
        }
    }
}

void depthwise_conv2d(Tensor3D* input, Weight4D* weight, Tensor1D_32* bias, Tensor3D* output, int stride, int padding) {
    int out_h = output->height;
    int out_w = output->width;
    
    for (int oc = 0; oc < weight->out_channels; oc++) {
        for (int oh = 0; oh < out_h; oh++) {
            for (int ow = 0; ow < out_w; ow++) {
                
                int32_t sum = bias ? bias->data[oc] : 0;
                
                for (int kh = 0; kh < weight->kernel_h; kh++) {
                    for (int kw = 0; kw < weight->kernel_w; kw++) {
                        
                        int ih = oh * stride - padding + kh;
                        int iw = ow * stride - padding + kw;
                        
                        if (ih >= 0 && ih < input->height && iw >= 0 && iw < input->width) {
                            int in_idx = oc * (input->height * input->width) + ih * input->width + iw;
                            int w_idx = oc * (weight->kernel_h * weight->kernel_w) + kh * weight->kernel_w + kw;
                            
                            sum += (int32_t)input->data[in_idx] * (int32_t)weight->data[w_idx];
                        }
                    }
                }
                
                int out_idx = oc * (out_h * out_w) + oh * out_w + ow;
                output->data[out_idx] = clamp_to_int16(sum >> Q_FRAC_BITS);
            }
        }
    }
}
