#include "qface_model.h"
#include "qface_params.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define AO_BASE 0
#define WGT_BASE 0
#define OUT_BASE 300000
#define LANES 16

static void dump_hex64(const char *path, const int64_t *data, int count)
{
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        exit(1);
    }
    for (int i = 0; i < count; i++) {
        fprintf(fp, "%016llx\n", (unsigned long long)(uint64_t)data[i]);
    }
    fclose(fp);
}

static void dump_hex32(const char *path, const int32_t *data, int count)
{
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        exit(1);
    }
    for (int i = 0; i < count; i++) {
        fprintf(fp, "%08x\n", (unsigned int)(uint32_t)data[i]);
    }
    fclose(fp);
}

static void dump_hex6_from_int(const char *path, const int *data, int count)
{
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        exit(1);
    }
    for (int i = 0; i < count; i++) {
        fprintf(fp, "%02x\n", data[i] & 0x3f);
    }
    fclose(fp);
}

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

static int op_out_h(const qf_op_t *op)
{
    return (op->in_h + 2 * op->pad_h - op->kh) / op->stride_h + 1;
}

static int op_out_w(const qf_op_t *op)
{
    return (op->in_w + 2 * op->pad_w - op->kw) / op->stride_w + 1;
}

static void print_word(FILE *fp, int addr, const int8_t *data, int valid_lanes)
{
    uint64_t lo = 0;
    uint64_t hi = 0;
    for (int lane = 0; lane < valid_lanes; lane++) {
        uint64_t byte = (uint8_t)data[lane];
        if (lane < 8) {
            lo |= byte << (lane * 8);
        } else {
            hi |= byte << ((lane - 8) * 8);
        }
    }
    fprintf(fp, "%d %016llx%016llx\n",
            addr, (unsigned long long)hi, (unsigned long long)lo);
}

static int64_t conv_raw_acc(const qf_op_t *op, const int8_t *in, int oh, int ow, int oc)
{
    const int8_t *w = qf_weight + op->weight_off;
    int64_t acc = 0;

    for (int ic = 0; ic < op->in_c; ic++) {
        for (int ky = 0; ky < op->kh; ky++) {
            int ih = oh * op->stride_h + ky - op->pad_h;
            for (int kx = 0; kx < op->kw; kx++) {
                int iw = ow * op->stride_w + kx - op->pad_w;
                int8_t in_value;
                if (ih < 0 || ih >= op->in_h || iw < 0 || iw >= op->in_w) {
                    in_value = (int8_t)(-op->in_zero_point);
                } else {
                    in_value = in[(ih * op->in_w + iw) * op->in_c + ic];
                }
                int w_idx = ((oc * op->in_c + ic) * op->kh + ky) * op->kw + kx;
                acc += (int64_t)in_value * (int64_t)w[w_idx];
            }
        }
    }
    return acc;
}

static int8_t conv_quant_value(const qf_op_t *op, const int8_t *act, int x, int y, int oc)
{
    const int64_t *bias = qf_bias + op->bias_off;
    const int32_t *mult = qf_mult + op->param_off;
    const int32_t *prelu_mult = qf_prelu_mult + op->param_off;
    const int *shift = qf_shift + op->param_off;
    const int *prelu_shift = qf_prelu_shift + op->param_off;

    int64_t acc = conv_raw_acc(op, act, x, y, oc);
    int64_t work = (acc << QF_BIAS_SHIFT) + bias[oc];
    if (op->mode == QF_MODE_PRELU && work < 0) {
        work = round_shift_i64(work * (int64_t)prelu_mult[oc], prelu_shift[oc]);
    }

    return clamp_i8(round_shift_i64(work * (int64_t)mult[oc],
                                    shift[oc] + QF_BIAS_SHIFT) +
                    op->out_zero_point_add);
}

static void dump_activation_words(const char *path, const qf_op_t *op, const int8_t *act)
{
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        exit(1);
    }

    const int in_words = (op->in_c + LANES - 1) / LANES;
    for (int x = 0; x < op->in_h; x++) {
        for (int y = 0; y < op->in_w; y++) {
            for (int tile = 0; tile < op->in_c; tile += LANES) {
                int8_t lanes[LANES] = {0};
                int addr = AO_BASE + (x * op->in_w + y) * in_words + (tile / LANES);
                int valid = op->in_c - tile;
                if (valid > LANES) {
                    valid = LANES;
                }
                for (int lane = 0; lane < valid; lane++) {
                    lanes[lane] = act[(x * op->in_w + y) * op->in_c + tile + lane];
                }
                print_word(fp, addr, lanes, LANES);
            }
        }
    }
    fclose(fp);
}

static void dump_weight_words(const char *path, const qf_op_t *op)
{
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        exit(1);
    }

    const int8_t *w = qf_weight + op->weight_off;
    const int oc_words = op->out_c / LANES;
    for (int ic = 0; ic < op->in_c; ic++) {
        for (int pos = 0; pos < op->kh * op->kw; pos++) {
            int ky = pos / op->kw;
            int kx = pos % op->kw;
            for (int tile = 0; tile < op->out_c; tile += LANES) {
                int8_t lanes[LANES];
                int addr = WGT_BASE + (ic * op->kh * op->kw + pos) * oc_words + (tile / LANES);
                for (int lane = 0; lane < LANES; lane++) {
                    int oc = tile + lane;
                    int w_idx = ((oc * op->in_c + ic) * op->kh + ky) * op->kw + kx;
                    lanes[lane] = w[w_idx];
                }
                print_word(fp, addr, lanes, LANES);
            }
        }
    }
    fclose(fp);
}

static void dump_expected_words(const char *path, const qf_op_t *op, const int8_t *act)
{
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        exit(1);
    }

    int out_h = op_out_h(op);
    int out_w = op_out_w(op);
    for (int x = 0; x < out_h; x++) {
        for (int y = 0; y < out_w; y++) {
            for (int tile = 0; tile < op->out_c; tile += LANES) {
                int8_t lanes[LANES];
                int elem = (x * out_w + y) * op->out_c + tile;
                int addr = OUT_BASE + elem / LANES;
                for (int lane = 0; lane < LANES; lane++) {
                    lanes[lane] = conv_quant_value(op, act, x, y, tile + lane);
                }
                print_word(fp, addr, lanes, LANES);
            }
        }
    }
    fclose(fp);
}

static void dump_quant_params(const qf_op_t *op)
{
    static const int64_t zero64[1] = {0};
    static const int32_t one32[1] = {1};
    static const int zero_shift[1] = {0};

    dump_hex64("generated/spatial_top_conv3x3_bias.hex", qf_bias + op->bias_off, op->out_c);
    dump_hex32("generated/spatial_top_conv3x3_requant_mult.hex", qf_mult + op->param_off, op->out_c);
    dump_hex6_from_int("generated/spatial_top_conv3x3_requant_shift.hex", qf_shift + op->param_off, op->out_c);
    dump_hex32("generated/spatial_top_conv3x3_prelu_mult.hex", qf_prelu_mult + op->param_off, op->out_c);
    dump_hex6_from_int("generated/spatial_top_conv3x3_prelu_shift.hex", qf_prelu_shift + op->param_off, op->out_c);

    dump_hex32("generated/spatial_top_conv3x3_residual_mult.hex", one32, 1);
    dump_hex6_from_int("generated/spatial_top_conv3x3_residual_shift.hex", zero_shift, 1);
    dump_hex64("generated/spatial_top_conv3x3_residual_zero_point.hex", zero64, 1);
}

int main(void)
{
    const qf_op_t *op = &qf_ops[0];
    if (!(op->type == QF_OP_CONV && op->groups == 1 &&
          op->in_c == 3 && op->out_c == 64 && op->kh == 3 && op->kw == 3)) {
        fprintf(stderr, "op0 is not the expected first Conv3x3\n");
        return 1;
    }

    dump_activation_words("generated/spatial_top_conv3x3_ao_init.txt", op, qf_input);
    dump_weight_words("generated/spatial_top_conv3x3_wgt_init.txt", op);
    dump_expected_words("generated/spatial_top_conv3x3_expected.txt", op, qf_input);
    dump_quant_params(op);

    printf("dumped first Conv3x3: in=%dx%dx%d out=%dx%dx%d pad_value=%d\n",
           op->in_h, op->in_w, op->in_c, op_out_h(op), op_out_w(op), op->out_c,
           -op->in_zero_point);
    return 0;
}
