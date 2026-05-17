#include "qface_model.h"
#include "qface_params.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DUMP_OP_INDEX 1
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

static void run_conv_quant(const qf_op_t *op, const int8_t *in, int8_t *out)
{
    const int8_t *w = qf_weight + op->weight_off;
    const int64_t *bias = qf_bias + op->bias_off;
    const int32_t *mult = qf_mult + op->param_off;
    const int32_t *prelu_mult = qf_prelu_mult + op->param_off;
    const int *shift = qf_shift + op->param_off;
    const int *prelu_shift = qf_prelu_shift + op->param_off;

    const int out_h = op_out_h(op);
    const int out_w = op_out_w(op);
    const int depthwise = (op->groups == op->in_c && op->out_c == op->in_c);

    for (int oh = 0; oh < out_h; oh++) {
        for (int ow = 0; ow < out_w; ow++) {
            for (int oc = 0; oc < op->out_c; oc++) {
                int64_t acc = 0;
                int ic_start = depthwise ? oc : 0;
                int ic_end = depthwise ? oc + 1 : op->in_c;
                for (int ic = ic_start; ic < ic_end; ic++) {
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

                            int w_idx;
                            if (depthwise) {
                                w_idx = oc * op->kh * op->kw + ky * op->kw + kx;
                            } else {
                                w_idx = ((oc * op->in_c + ic) * op->kh + ky) * op->kw + kx;
                            }
                            acc += (int64_t)in_value * (int64_t)w[w_idx];
                        }
                    }
                }

                int64_t work = (acc << QF_BIAS_SHIFT) + bias[oc];
                if (op->mode == QF_MODE_PRELU && work < 0) {
                    work = round_shift_i64(work * (int64_t)prelu_mult[oc], prelu_shift[oc]);
                }

                int64_t q = round_shift_i64(work * (int64_t)mult[oc], shift[oc] + QF_BIAS_SHIFT) +
                            op->out_zero_point_add;
                out[(oh * out_w + ow) * op->out_c + oc] = clamp_i8(q);
            }
        }
    }
}

static int64_t dw_raw_acc(const qf_op_t *op, const int8_t *in, int oh, int ow, int ch)
{
    const int8_t *w = qf_weight + op->weight_off;
    int64_t acc = 0;

    for (int ky = 0; ky < op->kh; ky++) {
        int ih = oh * op->stride_h + ky - op->pad_h;
        for (int kx = 0; kx < op->kw; kx++) {
            int iw = ow * op->stride_w + kx - op->pad_w;
            int8_t in_value;
            if (ih < 0 || ih >= op->in_h || iw < 0 || iw >= op->in_w) {
                // Match the current RTL spatial load path: padded windows are
                // injected as int8 zero in the local activation buffer.
                in_value = 0;
            } else {
                in_value = in[(ih * op->in_w + iw) * op->in_c + ch];
            }
            acc += (int64_t)in_value * (int64_t)w[ch * op->kh * op->kw + ky * op->kw + kx];
        }
    }
    return acc;
}

static int8_t dw_quant_value(const qf_op_t *op, const int8_t *act, int x, int y, int ch)
{
    const int64_t *bias = qf_bias + op->bias_off;
    const int32_t *mult = qf_mult + op->param_off;
    const int32_t *prelu_mult = qf_prelu_mult + op->param_off;
    const int *shift = qf_shift + op->param_off;
    const int *prelu_shift = qf_prelu_shift + op->param_off;

    int64_t acc = dw_raw_acc(op, act, x, y, ch);
    int64_t work = (acc << QF_BIAS_SHIFT) + bias[ch];
    if (op->mode == QF_MODE_PRELU && work < 0) {
        work = round_shift_i64(work * (int64_t)prelu_mult[ch], prelu_shift[ch]);
    }

    return clamp_i8(round_shift_i64(work * (int64_t)mult[ch],
                                    shift[ch] + QF_BIAS_SHIFT) +
                    op->out_zero_point_add);
}

static void dump_activation_words(const char *path, const qf_op_t *op, const int8_t *act)
{
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        exit(1);
    }

    for (int x = 0; x < op->in_h; x++) {
        for (int y = 0; y < op->in_w; y++) {
            for (int tile = 0; tile < op->in_c; tile += LANES) {
                int addr = AO_BASE + (x * op->in_w + y) * op->in_c + tile;
                print_word(fp, addr, &act[(x * op->in_w + y) * op->in_c + tile], LANES);
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
    for (int pos = 0; pos < op->kh * op->kw; pos++) {
        for (int tile = 0; tile < op->out_c; tile += LANES) {
            int8_t lanes[LANES];
            int addr = WGT_BASE + pos * op->out_c + tile;
            for (int lane = 0; lane < LANES; lane++) {
                int ch = tile + lane;
                lanes[lane] = w[ch * op->kh * op->kw + pos];
            }
            print_word(fp, addr, lanes, LANES);
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
                int addr = OUT_BASE + elem;
                for (int lane = 0; lane < LANES; lane++) {
                    lanes[lane] = dw_quant_value(op, act, x, y, tile + lane);
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

    dump_hex64("generated/spatial_top_dw_bias.hex", qf_bias + op->bias_off, op->out_c);
    dump_hex32("generated/spatial_top_dw_requant_mult.hex", qf_mult + op->param_off, op->out_c);
    dump_hex6_from_int("generated/spatial_top_dw_requant_shift.hex", qf_shift + op->param_off, op->out_c);
    dump_hex32("generated/spatial_top_dw_prelu_mult.hex", qf_prelu_mult + op->param_off, op->out_c);
    dump_hex6_from_int("generated/spatial_top_dw_prelu_shift.hex", qf_prelu_shift + op->param_off, op->out_c);

    // This op is PReLU-only; keep residual banks initialized to harmless values
    // so the formal quant_param_mem interface remains fully connected.
    dump_hex32("generated/spatial_top_dw_residual_mult.hex", one32, 1);
    dump_hex6_from_int("generated/spatial_top_dw_residual_shift.hex", zero_shift, 1);
    dump_hex64("generated/spatial_top_dw_residual_zero_point.hex", zero64, 1);
}

int main(void)
{
    const qf_op_t *op0 = &qf_ops[0];
    const qf_op_t *op = &qf_ops[DUMP_OP_INDEX];
    if (!(op->type == QF_OP_CONV && op->groups == op->in_c &&
          op->out_c == op->in_c && op->kh == 3 && op->kw == 3)) {
        fprintf(stderr, "op %d is not a supported DWConv3x3 op\n", DUMP_OP_INDEX);
        return 1;
    }

    int8_t *op1_input = (int8_t *)calloc((size_t)op->in_h * op->in_w * op->in_c, sizeof(int8_t));
    if (!op1_input) {
        return 1;
    }

    run_conv_quant(op0, qf_input, op1_input);
    dump_activation_words("generated/spatial_top_dw_ao_init.txt", op, op1_input);
    dump_weight_words("generated/spatial_top_dw_wgt_init.txt", op);
    dump_expected_words("generated/spatial_top_dw_expected.txt", op, op1_input);
    dump_quant_params(op);

    printf("dumped op=%d in=%dx%dx%d out=%dx%dx%d words=%d\n",
           DUMP_OP_INDEX, op->in_h, op->in_w, op->in_c,
           op_out_h(op), op_out_w(op), op->out_c,
           op_out_h(op) * op_out_w(op) * op->out_c / LANES);

    free(op1_input);
    return 0;
}
