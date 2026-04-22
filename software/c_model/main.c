#include <stdio.h>
#include <stdlib.h>
#include "tensor.h"
#include "io_dump.h"
#include "conv.h"
#include "activation.h"

// Helper generic runner for a fused Conv block
void run_conv_block(
    const char* prefix,
    int in_c, int in_h, int in_w,
    int out_c, int out_h, int out_w,
    int k_h, int k_w, int stride, int padding, int is_dw, int has_prelu) 
{
    char filepath[256];
    
    Tensor3D* input = create_tensor_3d(in_c, in_h, in_w);
    Weight4D* weight = create_weight_4d(out_c, is_dw ? 1 : in_c, k_h, k_w);
    Tensor1D* bias = create_tensor_1d(out_c);
    Tensor1D* prelu_w = has_prelu ? create_tensor_1d(out_c) : NULL;
    Tensor3D* output = create_tensor_3d(out_c, out_h, out_w);

    sprintf(filepath, "../golden/%s_in.txt", prefix);
    load_tensor_3d(filepath, input);
    
    sprintf(filepath, "../golden/%s_weight.txt", prefix);
    load_weight_4d(filepath, weight);
    
    sprintf(filepath, "../golden/%s_bias.txt", prefix);
    load_tensor_1d(filepath, bias);
    
    if (has_prelu) {
        sprintf(filepath, "../golden/%s_prelu.txt", prefix);
        load_tensor_1d(filepath, prelu_w);
    }

    if (is_dw) {
        depthwise_conv2d(input, weight, bias, output, stride, padding);
    } else {
        conv2d(input, weight, bias, output, stride, padding);
    }

    if (has_prelu) {
        prelu_inplace(output, prelu_w);
    }

    sprintf(filepath, "../golden/%s_out_c.txt", prefix);
    dump_tensor_3d(filepath, output);

    free_tensor_3d(input);
    free_weight_4d(weight);
    free_tensor_1d(bias);
    if (prelu_w) free_tensor_1d(prelu_w);
    free_tensor_3d(output);
}

void test_layer0_standard_conv() {
    printf("-> Running Layer 0 (Standard Conv)\n");
    run_conv_block("layer0", 3, 112, 96, 64, 56, 48, 3, 3, 2, 1, 0, 1);
}

void test_layer1_depthwise_conv() {
    printf("-> Running Layer 1 (Depthwise Conv)\n");
    run_conv_block("layer1", 64, 56, 48, 64, 56, 48, 3, 3, 1, 1, 1, 1);
}

void test_layer2_bottleneck() {
    printf("-> Running Layer 2 (Bottleneck with Residual)\n");
    // Bottleneck Expansion: 64 -> 128 (1x1 Conv, s=1, p=0)
    run_conv_block("layer2_pw1", 64, 56, 48, 128, 56, 48, 1, 1, 1, 0, 0, 1);
    
    // Bottleneck Depthwise: 128 -> 128 (3x3 DW, s=2, p=1)
    run_conv_block("layer2_dw", 128, 56, 48, 128, 28, 24, 3, 3, 2, 1, 1, 1);
    
    // Bottleneck Projection: 128 -> 64 (1x1 Conv, s=1, p=0, Linear=No PReLU)
    run_conv_block("layer2_pw2", 128, 28, 24, 64, 28, 24, 1, 1, 1, 0, 0, 0);
}

void test_layer3_bottleneck_residual() {
    printf("-> Running Layer 3 (Bottleneck with TRUE Residual)\n");
    // Expansion: 64 -> 128
    run_conv_block("layer3_pw1", 64, 28, 24, 128, 28, 24, 1, 1, 1, 0, 0, 1);
    // Depthwise: 128 -> 128
    run_conv_block("layer3_dw", 128, 28, 24, 128, 28, 24, 3, 3, 1, 1, 1, 1);
    // Projection: 128 -> 64
    run_conv_block("layer3_pw2", 128, 28, 24, 64, 28, 24, 1, 1, 1, 0, 0, 0);

    // Now test the residual addition
    Tensor3D* residual_in = create_tensor_3d(64, 28, 24);
    Tensor3D* residual_out = create_tensor_3d(64, 28, 24);

    load_tensor_3d("../golden/layer3_residual_in.txt", residual_in);
    load_tensor_3d("../golden/layer3_pw2_out_c.txt", residual_out);

    add_tensor_inplace(residual_out, residual_in);

    dump_tensor_3d("../golden/layer3_residual_out_c.txt", residual_out);

    free_tensor_3d(residual_in);
    free_tensor_3d(residual_out);
}

int main(int argc, char** argv) {
    printf("Starting C Reference Model Verification Suite...\n");
    test_layer0_standard_conv();
    test_layer1_depthwise_conv();
    test_layer2_bottleneck();
    test_layer3_bottleneck_residual();

    printf("Done.\n");
    return 0;
}
