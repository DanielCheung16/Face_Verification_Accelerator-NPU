#include "conv.h"

// Helper to access NCHW layout safely
static inline float get_data(Tensor3D* t, int c, int h, int w) {
    return t->data[c * (t->height * t->width) + h * t->width + w];
}

static inline void set_data(Tensor3D* t, int c, int h, int w, float val) {
    t->data[c * (t->height * t->width) + h * t->width + w] = val;
}

static inline float get_weight(Weight4D* w, int oc, int ic, int kh, int kw) {
    int spatial = w->kernel_h * w->kernel_w;
    int index = oc * (w->in_channels * spatial) + ic * spatial + kh * w->kernel_w + kw;
    return w->data[index];
}

void conv2d(
    Tensor3D* input, 
    Weight4D* weight, 
    Tensor1D* bias, 
    Tensor3D* output,
    int stride, 
    int padding) 
{
    int out_c = output->channels;
    int out_h = output->height;
    int out_w = output->width;
    
    int in_c = input->channels;
    int in_h = input->height;
    int in_w = input->width;
    
    int k_h = weight->kernel_h;
    int k_w = weight->kernel_w;

    // Loop ordering represents a naive nested loop, similar to what a simple MAC array schedules
    for (int oc = 0; oc < out_c; oc++) {
        float b = (bias != NULL) ? bias->data[oc] : 0.0f;
        for (int oh = 0; oh < out_h; oh++) {
            for (int ow = 0; ow < out_w; ow++) {
                
                float sum = b;
                
                // Sliding window
                for (int ic = 0; ic < in_c; ic++) {
                    for (int kh = 0; kh < k_h; kh++) {
                        for (int kw = 0; kw < k_w; kw++) {
                            int ih = oh * stride - padding + kh;
                            int iw = ow * stride - padding + kw;
                            
                            // Check out of bounds (zero padding)
                            if (ih >= 0 && ih < in_h && iw >= 0 && iw < in_w) {
                                float in_val = get_data(input, ic, ih, iw);
                                float wt_val = get_weight(weight, oc, ic, kh, kw);
                                sum += in_val * wt_val;
                            }
                        }
                    }
                }
                
                set_data(output, oc, oh, ow, sum);
            }
        }
    }
}

void depthwise_conv2d(
    Tensor3D* input, 
    Weight4D* weight, 
    Tensor1D* bias, 
    Tensor3D* output,
    int stride, 
    int padding) 
{
    int channels = input->channels; // out_c == in_c
    int out_h = output->height;
    int out_w = output->width;
    
    int in_h = input->height;
    int in_w = input->width;
    
    int k_h = weight->kernel_h;
    int k_w = weight->kernel_w;

    for (int c = 0; c < channels; c++) {
        float b = (bias != NULL) ? bias->data[c] : 0.0f;
        for (int oh = 0; oh < out_h; oh++) {
            for (int ow = 0; ow < out_w; ow++) {
                
                float sum = b;
                
                // Sliding window for single channel
                for (int kh = 0; kh < k_h; kh++) {
                    for (int kw = 0; kw < k_w; kw++) {
                        int ih = oh * stride - padding + kh;
                        int iw = ow * stride - padding + kw;
                        
                        if (ih >= 0 && ih < in_h && iw >= 0 && iw < in_w) {
                            float in_val = get_data(input, c, ih, iw);
                            // Weight layout for depthwise in PyTorch is (C, 1, K, K)
                            float wt_val = get_weight(weight, c, 0, kh, kw);
                            sum += in_val * wt_val;
                        }
                    }
                }
                
                set_data(output, c, oh, ow, sum);
            }
        }
    }
}
