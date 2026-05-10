#include "qface_model.h"
#include "qface_params.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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

static float dequant_i8(int8_t q, float scale, int zp)
{
    return ((float)q + (float)zp) / scale;
}

static int8_t quant_i8_from_float(float x, float scale, int zp)
{
    long q = lroundf(x * scale - (float)zp);
    if (q > 127) {
        q = 127;
    }
    if (q < -128) {
        q = -128;
    }
    return (int8_t)q;
}

static int op_out_h(const qf_op_t *op)
{
    return (op->in_h + 2 * op->pad_h - op->kh) / op->stride_h + 1;
}

static int op_out_w(const qf_op_t *op)
{
    return (op->in_w + 2 * op->pad_w - op->kw) / op->stride_w + 1;
}

static void run_conv_op(const qf_op_t *op, const int8_t *in, int8_t *out)
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
                                int in_idx = (ih * op->in_w + iw) * op->in_c + ic;
                                in_value = in[in_idx];
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

static void run_residual_quant_op(const qf_op_t *op, const int8_t *main_in, const int8_t *res_in, int8_t *out)
{
    const int total = op->in_h * op->in_w * op->in_c;
    for (int i = 0; i < total; i++) {
        float x = dequant_i8(main_in[i], op->in_scale, op->in_zero_point) +
                  dequant_i8(res_in[i], op->res_scale, op->res_zero_point);
        out[i] = quant_i8_from_float(x, op->out_scale, op->out_zero_point);
    }
}

static void run_linear_op(const qf_op_t *op, const int8_t *in, float *out)
{
    const int8_t *w = qf_weight + op->weight_off;
    const float *scale = qf_final_scale + op->param_off;
    const float *bias = qf_final_bias + op->bias_off;
    for (int oc = 0; oc < op->out_c; oc++) {
        int64_t acc = 0;
        for (int ic = 0; ic < op->in_c; ic++) {
            acc += (int64_t)in[ic] * (int64_t)w[oc * op->in_c + ic];
        }
        out[oc] = (float)acc * scale[oc] + bias[oc];
    }
}

static int run_program(const int8_t *input_nhwc, int8_t *output_nhwc, qf_tensor_shape_t *shape,
                       float *embedding)
{
    int8_t *buf0 = (int8_t *)calloc(QF_MAX_ACT, sizeof(int8_t));
    int8_t *buf1 = (int8_t *)calloc(QF_MAX_ACT, sizeof(int8_t));
    int8_t *res = (int8_t *)calloc(QF_MAX_ACT, sizeof(int8_t));
    if (!buf0 || !buf1 || !res) {
        free(buf0);
        free(buf1);
        free(res);
        return -1;
    }

    memcpy(buf0, input_nhwc, QF_INPUT_SIZE);
    int8_t *cur = buf0;
    int8_t *nxt = buf1;
    qf_tensor_shape_t cur_shape = {QF_INPUT_H, QF_INPUT_W, QF_INPUT_C};
    int output_kind = QF_OUTPUT_I8;

    for (int i = 0; i < QF_NUM_OPS; i++) {
        const qf_op_t *op = &qf_ops[i];
        if (op->type == QF_OP_SAVE_RES) {
            memcpy(res, cur, (size_t)op->in_h * op->in_w * op->in_c);
        } else if (op->type == QF_OP_CONV) {
            run_conv_op(op, cur, nxt);
            cur_shape.h = op_out_h(op);
            cur_shape.w = op_out_w(op);
            cur_shape.c = op->out_c;
            int8_t *tmp = cur;
            cur = nxt;
            nxt = tmp;
        } else if (op->type == QF_OP_RES_ADD) {
            run_residual_quant_op(op, cur, res, nxt);
            cur_shape.h = op->in_h;
            cur_shape.w = op->in_w;
            cur_shape.c = op->in_c;
            int8_t *tmp = cur;
            cur = nxt;
            nxt = tmp;
        } else if (op->type == QF_OP_LINEAR) {
            run_linear_op(op, cur, embedding);
            output_kind = QF_OUTPUT_EMBED;
        }
    }

    if (output_kind == QF_OUTPUT_I8 && output_nhwc) {
        int size = cur_shape.h * cur_shape.w * cur_shape.c;
        memcpy(output_nhwc, cur, (size_t)size);
    }
    if (shape) {
        *shape = cur_shape;
    }

    free(buf0);
    free(buf1);
    free(res);
    return output_kind;
}

int qface_run_embedding(const int8_t *input_nhwc, float *embedding)
{
    if (!input_nhwc || !embedding || QF_OUTPUT_KIND != QF_OUTPUT_EMBED) {
        return -1;
    }
    int kind = run_program(input_nhwc, NULL, NULL, embedding);
    return kind == QF_OUTPUT_EMBED ? 0 : -1;
}

int qface_run_i8(const int8_t *input_nhwc, int8_t *output_nhwc, qf_tensor_shape_t *shape)
{
    if (!input_nhwc || !output_nhwc || QF_OUTPUT_KIND != QF_OUTPUT_I8) {
        return -1;
    }
    int kind = run_program(input_nhwc, output_nhwc, shape, NULL);
    return kind == QF_OUTPUT_I8 ? 0 : -1;
}

int qface_compare_embedding(const float *embedding, float *mae, float *rmse, float *max_abs, float *cosine)
{
    if (!embedding || QF_OUTPUT_KIND != QF_OUTPUT_EMBED) {
        return -1;
    }

    double abs_sum = 0.0;
    double sq_sum = 0.0;
    double dot = 0.0;
    double norm_a = 0.0;
    double norm_b = 0.0;
    double max_v = 0.0;
    for (int i = 0; i < QF_EMBED; i++) {
        double diff = (double)embedding[i] - (double)qf_true_embedding[i];
        double ad = fabs(diff);
        abs_sum += ad;
        sq_sum += diff * diff;
        if (ad > max_v) {
            max_v = ad;
        }
        dot += (double)embedding[i] * (double)qf_true_embedding[i];
        norm_a += (double)embedding[i] * (double)embedding[i];
        norm_b += (double)qf_true_embedding[i] * (double)qf_true_embedding[i];
    }

    if (mae) {
        *mae = (float)(abs_sum / QF_EMBED);
    }
    if (rmse) {
        *rmse = (float)sqrt(sq_sum / QF_EMBED);
    }
    if (max_abs) {
        *max_abs = (float)max_v;
    }
    if (cosine) {
        *cosine = (float)(dot / (sqrt(norm_a) * sqrt(norm_b) + 1e-30));
    }
    return 0;
}

int qface_compare_i8(const int8_t *output_nhwc, int *mismatches)
{
    if (!output_nhwc || QF_OUTPUT_KIND != QF_OUTPUT_I8) {
        return -1;
    }
    int mm = 0;
    for (int i = 0; i < QF_GOLDEN_I8_SIZE; i++) {
        if (output_nhwc[i] != qf_true_output_i8[i]) {
            mm++;
        }
    }
    if (mismatches) {
        *mismatches = mm;
    }
    return 0;
}
