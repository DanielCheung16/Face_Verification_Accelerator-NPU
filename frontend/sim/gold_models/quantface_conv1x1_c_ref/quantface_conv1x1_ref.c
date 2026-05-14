#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "quantface_conv1x1_ref_data.h"

static int64_t round_shift_i64(int64_t value, int shift)
{
    if (shift == 0) {
        return value;
    }
    return (value + ((int64_t)1 << (shift - 1))) >> shift;
}

static int8_t clamp_i8(int64_t value)
{
    if (value > 127) {
        return 127;
    }
    if (value < -128) {
        return -128;
    }
    return (int8_t)value;
}

static const int8_t *layer_weight(int layer)
{
    return layer == 0 ? qf_weight_l0 : qf_weight_l1;
}

static const int8_t *layer_residual(int layer)
{
    return layer == 0 ? qf_residual_l0 : NULL;
}

static const int64_t *layer_bias(int layer)
{
    return layer == 0 ? qf_bias_l0 : qf_bias_l1;
}

static const int32_t *layer_mult(int layer)
{
    return layer == 0 ? qf_multiplier_l0 : qf_multiplier_l1;
}

static const int *layer_shift(int layer)
{
    return layer == 0 ? qf_shift_l0 : qf_shift_l1;
}

static const int32_t *layer_zero_point(int layer)
{
    return layer == 0 ? qf_zero_point_l0 : qf_zero_point_l1;
}

static const int32_t *layer_prelu_mult(int layer)
{
    return layer == 0 ? qf_prelu_multiplier_l0 : qf_prelu_multiplier_l1;
}

static const int *layer_prelu_shift(int layer)
{
    return layer == 0 ? qf_prelu_shift_l0 : qf_prelu_shift_l1;
}

static const int32_t *layer_residual_mult(int layer)
{
    return layer == 0 ? qf_residual_multiplier_l0 : qf_residual_multiplier_l1;
}

static const int *layer_residual_shift(int layer)
{
    return layer == 0 ? qf_residual_shift_l0 : qf_residual_shift_l1;
}

static const int32_t *layer_residual_zp(int layer)
{
    return layer == 0 ? qf_residual_zero_point_l0 : qf_residual_zero_point_l1;
}

static void run_layer(int layer, const int8_t *input, int8_t *output)
{
    const qf_layer_cfg_t cfg = qf_layers[layer];
    const int8_t *weight = layer_weight(layer);
    const int8_t *residual = layer_residual(layer);
    const int64_t *bias = layer_bias(layer);
    const int32_t *mult = layer_mult(layer);
    const int *shift = layer_shift(layer);
    const int32_t *zero_point = layer_zero_point(layer);
    const int32_t *prelu_mult = layer_prelu_mult(layer);
    const int *prelu_shift = layer_prelu_shift(layer);
    const int32_t *res_mult = layer_residual_mult(layer);
    const int *res_shift = layer_residual_shift(layer);
    const int32_t *res_zp = layer_residual_zp(layer);

    for (int m = 0; m < cfg.m; m++) {
        for (int n = 0; n < cfg.n; n++) {
            int64_t acc = 0;
            for (int k = 0; k < cfg.k; k++) {
                acc += (int64_t)input[m * cfg.k + k] * (int64_t)weight[k * cfg.n + n];
            }

            int64_t work = (acc << QF_BIAS_SHIFT) + bias[n];

            if (cfg.mode == QF_MODE_RESIDUAL && residual != NULL) {
                int64_t centered = (int64_t)residual[m * cfg.n + n] + (int64_t)res_zp[n];
                int64_t scaled = round_shift_i64(centered * (int64_t)res_mult[n], res_shift[n]);
                work += scaled << QF_BIAS_SHIFT;
            } else if (cfg.mode == QF_MODE_PRELU && (work < 0)) {
                work = round_shift_i64(work * (int64_t)prelu_mult[n], prelu_shift[n]);
            }

            output[m * cfg.n + n] = clamp_i8(round_shift_i64(work * (int64_t)mult[n],
                                                             shift[n] + QF_BIAS_SHIFT) +
                                             (int64_t)zero_point[n]);
        }
    }
}

int main(void)
{
    int8_t *buf0 = (int8_t *)malloc((size_t)QF_MAX_M * QF_MAX_CH);
    int8_t *buf1 = (int8_t *)malloc((size_t)QF_MAX_M * QF_MAX_CH);
    if (buf0 == NULL || buf1 == NULL) {
        fprintf(stderr, "allocation failed\n");
        free(buf0);
        free(buf1);
        return 1;
    }

    for (int i = 0; i < QF_L0_M * QF_L0_K; i++) {
        buf0[i] = qf_input_l0[i];
    }

    run_layer(0, buf0, buf1);
    run_layer(1, buf1, buf0);

    int mismatches = 0;
    int true_mismatches = 0;
    int max_abs = 0;
    int64_t abs_sum = 0;
    const int total = QF_L1_M * QF_L1_N;

    for (int i = 0; i < total; i++) {
        int diff = (int)buf0[i] - (int)qf_expected_l1[i];
        if (diff != 0) {
            mismatches++;
        }

        int true_diff = (int)buf0[i] - (int)qf_true_l1[i];
        if (true_diff < 0) {
            true_diff = -true_diff;
        }
        if (true_diff != 0) {
            true_mismatches++;
        }
        if (true_diff > max_abs) {
            max_abs = true_diff;
        }
        abs_sum += true_diff;
    }

    printf("C vs Python fixed-point golden: mismatches=%d / %d\n", mismatches, total);
    printf("C vs QuantFace true quantized: mae=%.6f max_abs=%d mismatches=%d / %d\n",
           (double)abs_sum / (double)total, max_abs, true_mismatches, total);

    free(buf0);
    free(buf1);
    return mismatches == 0 ? 0 : 2;
}
