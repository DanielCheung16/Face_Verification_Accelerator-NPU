#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "quantface_conv1x1_ref_data.h"

#define QF_DATA_W 8
#define QF_GB_LANES 16
#define QF_AO_DEPTH 65536
#define QF_WGT_DEPTH 65536
#define QF_AO_IN_BASE 0
#define QF_AO_OUT_BASE 32768
#define QF_AO_RES_BASE 8192
#define QF_WGT0_BASE 0
#define QF_WGT1_BASE (QF_L0_K * ((QF_L0_N + QF_GB_LANES - 1) / QF_GB_LANES))

typedef struct {
    uint64_t lo;
    uint64_t hi;
} qf_word128_t;

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

static void set_lane(qf_word128_t *word, int lane, int8_t value)
{
    uint64_t byte = (uint8_t)value;
    if (lane < 8) {
        word->lo |= byte << (lane * QF_DATA_W);
    } else {
        word->hi |= byte << ((lane - 8) * QF_DATA_W);
    }
}

static void pack_activation(qf_word128_t *mem, int base, const int8_t *mat, int m_size, int channels)
{
    int tiles = (channels + QF_GB_LANES - 1) / QF_GB_LANES;

    for (int m = 0; m < m_size; m++) {
        for (int tile = 0; tile < tiles; tile++) {
            qf_word128_t word = {0, 0};
            for (int lane = 0; lane < QF_GB_LANES; lane++) {
                int c = tile * QF_GB_LANES + lane;
                set_lane(&word, lane, c < channels ? mat[m * channels + c] : 0);
            }
            mem[base + m * tiles + tile] = word;
        }
    }
}

static void pack_weight(qf_word128_t *mem, int base, const int8_t *weight, int k_size, int n_size)
{
    int n_tiles = (n_size + QF_GB_LANES - 1) / QF_GB_LANES;

    for (int k = 0; k < k_size; k++) {
        for (int tile = 0; tile < n_tiles; tile++) {
            qf_word128_t word = {0, 0};
            for (int lane = 0; lane < QF_GB_LANES; lane++) {
                int n = tile * QF_GB_LANES + lane;
                set_lane(&word, lane, n < n_size ? weight[k * n_size + n] : 0);
            }
            mem[base + k * n_tiles + tile] = word;
        }
    }
}

static int write_hex(const char *path, const qf_word128_t *mem, int depth)
{
    FILE *fp = fopen(path, "w");
    if (fp == NULL) {
        fprintf(stderr, "failed to open %s: %s\n", path, strerror(errno));
        return 1;
    }

    for (int i = 0; i < depth; i++) {
        fprintf(fp, "%016llx%016llx\n",
                (unsigned long long)mem[i].hi,
                (unsigned long long)mem[i].lo);
    }

    fclose(fp);
    return 0;
}

static int ensure_dir(const char *path)
{
    if (mkdir(path, 0775) == 0 || errno == EEXIST) {
        return 0;
    }

    fprintf(stderr, "failed to create %s: %s\n", path, strerror(errno));
    return 1;
}

static void make_path(char *dst, size_t dst_size, const char *dir, const char *name)
{
    snprintf(dst, dst_size, "%s/%s", dir, name);
}

int main(int argc, char **argv)
{
    const char *out_dir = argc > 1 ? argv[1] : "out";
    qf_word128_t *ao_mem = calloc(QF_AO_DEPTH, sizeof(qf_word128_t));
    qf_word128_t *wgt_mem = calloc(QF_WGT_DEPTH, sizeof(qf_word128_t));
    qf_word128_t *golden_mem = calloc(QF_AO_DEPTH, sizeof(qf_word128_t));
    int8_t *buf0 = (int8_t *)malloc((size_t)QF_MAX_M * QF_MAX_CH);
    int8_t *buf1 = (int8_t *)malloc((size_t)QF_MAX_M * QF_MAX_CH);
    char path[512];
    int rc = 0;

    if (ao_mem == NULL || wgt_mem == NULL || golden_mem == NULL || buf0 == NULL || buf1 == NULL) {
        fprintf(stderr, "allocation failed\n");
        rc = 1;
        goto done;
    }

    for (int i = 0; i < QF_L0_M * QF_L0_K; i++) {
        buf0[i] = qf_input_l0[i];
    }

    pack_activation(ao_mem, QF_AO_IN_BASE, qf_input_l0, QF_L0_M, QF_L0_K);
    pack_activation(ao_mem, QF_AO_RES_BASE, qf_residual_l0, QF_L0_M, QF_L0_N);
    pack_weight(wgt_mem, QF_WGT0_BASE, qf_weight_l0, QF_L0_K, QF_L0_N);
    pack_weight(wgt_mem, QF_WGT1_BASE, qf_weight_l1, QF_L1_K, QF_L1_N);

    run_layer(0, buf0, buf1);
    run_layer(1, buf1, buf0);
    pack_activation(golden_mem, QF_AO_IN_BASE, buf0, QF_L1_M, QF_L1_N);

    rc |= ensure_dir(out_dir);
    if (rc != 0) {
        goto done;
    }

    make_path(path, sizeof(path), out_dir, "quantface_conv1x1_c_ao_init.hex");
    rc |= write_hex(path, ao_mem, QF_AO_DEPTH);
    make_path(path, sizeof(path), out_dir, "quantface_conv1x1_c_wgt_init.hex");
    rc |= write_hex(path, wgt_mem, QF_WGT_DEPTH);
    make_path(path, sizeof(path), out_dir, "quantface_conv1x1_c_golden.hex");
    rc |= write_hex(path, golden_mem, QF_AO_DEPTH);

    if (rc == 0) {
        printf("Wrote C-generated SRAM hex images to %s\n", out_dir);
        printf("  ao_init: QF input @%d, residual @%d\n", QF_AO_IN_BASE, QF_AO_RES_BASE);
        printf("  wgt_init: layer0 @%d, layer1 @%d\n", QF_WGT0_BASE, QF_WGT1_BASE);
        printf("  golden: final output @%d\n", QF_AO_IN_BASE);
    }

done:
    free(ao_mem);
    free(wgt_mem);
    free(golden_mem);
    free(buf0);
    free(buf1);
    return rc == 0 ? 0 : 1;
}
