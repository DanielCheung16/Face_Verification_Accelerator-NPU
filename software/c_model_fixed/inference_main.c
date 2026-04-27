#include <stdio.h>
#include <stdlib.h>
#include "tensor.h"
#include "io_dump.h"
#include "conv.h"
#include "activation.h"

// Dynamically infers output size, allocates buffer, executes, and returns output tensor.
Tensor3D* run_conv_block_infer(
    const char* prefix, Tensor3D* input, 
    int out_c, int k_h, int k_w, int stride, int padding, 
    int is_dw, int has_prelu) 
{
    char filepath[256];
    int in_c = input->channels;
    int out_h = (input->height + 2 * padding - k_h) / stride + 1;
    int out_w = (input->width + 2 * padding - k_w) / stride + 1;
    
    Weight4D* weight = create_weight_4d(out_c, is_dw ? 1 : in_c, k_h, k_w);
    Tensor1D_32* bias = create_tensor_1d_32(out_c);
    Tensor1D_16* prelu_w = has_prelu ? create_tensor_1d_16(out_c) : NULL;
    Tensor3D* output = create_tensor_3d(out_c, out_h, out_w);

    sprintf(filepath, "../golden_weights_fixed/%s_weight.txt", prefix);
    load_weight_4d(filepath, weight);
    
    sprintf(filepath, "../golden_weights_fixed/%s_bias.txt", prefix);
    load_tensor_1d_32(filepath, bias);
    
    if (has_prelu) {
        sprintf(filepath, "../golden_weights_fixed/%s_prelu.txt", prefix);
        load_tensor_1d_16(filepath, prelu_w);
    }

    if (is_dw) {
        depthwise_conv2d(input, weight, bias, output, stride, padding);
    } else {
        conv2d(input, weight, bias, output, stride, padding);
    }

    if (has_prelu) {
        prelu_inplace(output, prelu_w);
    }

    free_weight_4d(weight);
    free_tensor_1d_32(bias);
    if (prelu_w) free_tensor_1d_16(prelu_w);
    
    return output;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        printf("Usage: %s <input.txt> <output.txt>\n", argv[0]);
        return 1;
    }
    
    printf("Initializing MobileFaceNet Full Inference Engine...\n");

    Tensor3D* x = create_tensor_3d(3, 112, 96);
    if (load_tensor_3d(argv[1], x) != 0) {
        printf("Error: Failed to load input image tensor from %s\n", argv[1]);
        return 1;
    }
    
    Tensor3D* next = NULL;

    printf("Running conv1...\n");
    next = run_conv_block_infer("conv1", x, 64, 3, 3, 2, 1, 0, 1);
    free_tensor_3d(x); x = next;
    
    printf("Running dw_conv1...\n");
    next = run_conv_block_infer("dw_conv1", x, 64, 3, 3, 1, 1, 1, 1);
    free_tensor_3d(x); x = next;
    
    int setting[5][4] = {
        {2, 64, 5, 2},
        {4, 128, 1, 2},
        {2, 128, 6, 1},
        {4, 128, 1, 2},
        {2, 128, 2, 1}
    };
    
    int block_idx = 0;
    int inplanes = 64;

    printf("Processing 15 Bottleneck blocks...\n");
    for (int s_idx = 0; s_idx < 5; s_idx++) {
        int t = setting[s_idx][0];
        int c = setting[s_idx][1];
        int n = setting[s_idx][2];
        int s = setting[s_idx][3];
        
        for (int i = 0; i < n; i++) {
            char prefix_pw1[64], prefix_dw[64], prefix_pw2[64];
            sprintf(prefix_pw1, "blocks_%d_pw1", block_idx);
            sprintf(prefix_dw, "blocks_%d_dw", block_idx);
            sprintf(prefix_pw2, "blocks_%d_pw2", block_idx);
            
            int stride = (i == 0) ? s : 1;
            int connect = (stride == 1 && inplanes == c);
            
            Tensor3D* shortcut = x;
            
            // PW1
            next = run_conv_block_infer(prefix_pw1, x, inplanes * t, 1, 1, 1, 0, 0, 1);
            if (!connect) free_tensor_3d(x); // Free early if not using shortcut
            x = next;
            
            if (block_idx == 0) {
                dump_tensor_3d("../golden/layer2_out_fixed.txt", x);
            }
            
            // DW
            next = run_conv_block_infer(prefix_dw, x, inplanes * t, 3, 3, stride, 1, 1, 1);
            free_tensor_3d(x); x = next;
            
            // PW2 (Linear)
            next = run_conv_block_infer(prefix_pw2, x, c, 1, 1, 1, 0, 0, 0);
            free_tensor_3d(x); x = next;
            
            if (connect) {
                add_tensor_inplace(x, shortcut);
                free_tensor_3d(shortcut);
            }
            
            inplanes = c;
            block_idx++;
        }
    }
    
    printf("Running conv2...\n");
    next = run_conv_block_infer("conv2", x, 512, 1, 1, 1, 0, 0, 1);
    free_tensor_3d(x); x = next;
    
    printf("Running linear7 (7x6 DW)...\n");
    next = run_conv_block_infer("linear7", x, 512, 7, 6, 1, 0, 1, 0);
    free_tensor_3d(x); x = next;
    
    printf("Running linear1 (128d output)...\n");
    next = run_conv_block_infer("linear1", x, 128, 1, 1, 1, 0, 0, 0);
    free_tensor_3d(x); x = next;
    
    // Export Final Result
    dump_tensor_3d(argv[2], x);
    free_tensor_3d(x);
    
    printf("Success! 128D Embedding saved to %s\n", argv[2]);
    return 0;
}
