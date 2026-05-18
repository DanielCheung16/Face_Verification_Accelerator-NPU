#include "qface_model.h"
#include "qface_params.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#define LANES 16
#define AO_DEPTH 65536
#define WGT_DEPTH 8192
#define AO_BASE0 0
#define AO_BASE1 10000
#define AO_BASE2 20000
#define AO_BASE3 30000
#define AO_BASE4 40000
#define WGT_BASE0 0
#define WGT_BASE1 2000
#define WGT_BASE2 4000
#define WGT_BASE3 6000
#define LINEAR_FC_PARAM_BASE 9664
#define LINEAR_FC_REQUANT_MULT 1
#define LINEAR_FC_REQUANT_SHIFT 8
#define LINEAR_FC_OUTPUT_ZERO_POINT 0
#define FULL_AO_BASE0 0
#define FULL_AO_BASE1 26000
#define FULL_AO_RES_BASE 52000
#define FULL_CFG_DEPTH 128
#define FULL_LAYER_PROFILE 13

typedef struct {
    uint64_t lo;
    uint64_t hi;
} word128_t;

typedef struct {
    int conv_op;
    int residual_op; // -1 when no fused residual
    int act_base;
    int wgt_base;
    int out_base;
    int residual_base;
} hw_layer_t;

typedef struct {
    int layer_valid;
    int layer_last;
    int layer_type;
    int k_size;
    int m_size;
    int n_size;
    int act_base;
    int wgt_base;
    int out_base;
    int residual_en;
    int residual_base;
    int ifmap_size_code;
    int num_filter_code;
    int stride;
    int pad;
    int pad_value;
    int mode;
    int output_zero_point;
    int bias_base;
    int requant_mult_base;
    int requant_shift_base;
    int prelu_mult_base;
    int prelu_shift_base;
    int residual_mult_base;
    int residual_shift_base;
    int residual_zero_point_base;
} layer_cfg_dump_t;

static int op_out_h(const qf_op_t *op) { return (op->in_h + 2 * op->pad_h - op->kh) / op->stride_h + 1; }
static int op_out_w(const qf_op_t *op) { return (op->in_w + 2 * op->pad_w - op->kw) / op->stride_w + 1; }
static int is_dw(const qf_op_t *op) { return op->groups == op->in_c && op->out_c == op->in_c; }

static int ifmap_size_code(int size)
{
    switch (size) {
        case 7: return 0;
        case 14: return 1;
        case 28: return 2;
        case 56: return 3;
        case 112: return 4;
        default: return 0;
    }
}

static int num_filter_code(int channels)
{
    switch (channels) {
        case 64: return 0;
        case 128: return 1;
        case 256: return 2;
        case 512: return 3;
        default: return 0;
    }
}

static int64_t round_shift_i64(int64_t value, int shift)
{
    return shift == 0 ? value : (value + ((int64_t)1 << (shift - 1))) >> shift;
}

static int8_t clamp_i8(int64_t value)
{
    if (value > 127) return 127;
    if (value < -128) return -128;
    return (int8_t)value;
}

static int choose_common_shift_double(const double *values, int count)
{
    double max_abs = 0.0;
    for (int i = 0; i < count; i++) {
        double a = fabs(values[i]);
        if (a > max_abs) max_abs = a;
    }
    if (max_abs <= 0.0) return 24;
    int shift = (int)floor(log2(((double)((int64_t)1 << 31) - 1.0) / max_abs));
    if (shift > 30) shift = 30;
    if (shift < 0) shift = 0;
    return shift;
}

static void write_hex64(const char *path, const int64_t *data, int count)
{
    FILE *fp = fopen(path, "w");
    if (!fp) { perror(path); exit(1); }
    for (int i = 0; i < count; i++) fprintf(fp, "%016llx\n", (unsigned long long)(uint64_t)data[i]);
    fclose(fp);
}

static void write_hex32(const char *path, const int32_t *data, int count)
{
    FILE *fp = fopen(path, "w");
    if (!fp) { perror(path); exit(1); }
    for (int i = 0; i < count; i++) fprintf(fp, "%08x\n", (unsigned int)(uint32_t)data[i]);
    fclose(fp);
}

static void write_hex6(const char *path, const int *data, int count)
{
    FILE *fp = fopen(path, "w");
    if (!fp) { perror(path); exit(1); }
    for (int i = 0; i < count; i++) fprintf(fp, "%02x\n", data[i] & 0x3f);
    fclose(fp);
}

static int write_mem_hex(const char *path, const word128_t *mem, int depth)
{
    FILE *fp = fopen(path, "w");
    if (!fp) { perror(path); return 1; }
    for (int i = 0; i < depth; i++) {
        fprintf(fp, "%016llx%016llx\n", (unsigned long long)mem[i].hi, (unsigned long long)mem[i].lo);
    }
    fclose(fp);
    return 0;
}

static void put_bits(uint64_t word[4], int *bit_pos, uint64_t value, int width)
{
    for (int i = 0; i < width; i++) {
        if ((value >> i) & 1ULL) {
            int pos = *bit_pos + i;
            word[pos / 64] |= 1ULL << (pos % 64);
        }
    }
    *bit_pos += width;
}

static void write_layer_config_hex(const char *path, const layer_cfg_dump_t *cfg, int count)
{
    FILE *fp = fopen(path, "w");
    if (!fp) { perror(path); exit(1); }
    for (int i = 0; i < FULL_CFG_DEPTH; i++) {
        const layer_cfg_dump_t *c = i < count ? &cfg[i] : NULL;
        uint64_t word[4] = {0, 0, 0, 0};
        int bit = 0;
        if (c) {
            put_bits(word, &bit, (uint64_t)c->residual_zero_point_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)c->residual_shift_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)c->residual_mult_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)c->prelu_shift_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)c->prelu_mult_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)c->requant_shift_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)c->requant_mult_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)c->bias_base & 0x3fffU, 14);
            put_bits(word, &bit, (uint64_t)(uint8_t)c->output_zero_point, 8);
            put_bits(word, &bit, (uint64_t)c->mode & 0x3U, 2);
            put_bits(word, &bit, (uint64_t)(uint8_t)c->pad_value, 8);
            put_bits(word, &bit, (uint64_t)c->pad & 0x1U, 1);
            put_bits(word, &bit, (uint64_t)c->stride & 0x1U, 1);
            put_bits(word, &bit, (uint64_t)c->num_filter_code & 0x3U, 2);
            put_bits(word, &bit, (uint64_t)c->ifmap_size_code & 0x7U, 3);
            put_bits(word, &bit, (uint64_t)c->residual_base & 0xffffU, 16);
            put_bits(word, &bit, (uint64_t)c->residual_en & 0x1U, 1);
            put_bits(word, &bit, (uint64_t)c->out_base & 0xffffU, 16);
            put_bits(word, &bit, (uint64_t)c->wgt_base & 0xffffU, 16);
            put_bits(word, &bit, (uint64_t)c->act_base & 0xffffU, 16);
            put_bits(word, &bit, (uint64_t)c->n_size & 0xffffU, 16);
            put_bits(word, &bit, (uint64_t)c->m_size & 0xffffU, 16);
            put_bits(word, &bit, (uint64_t)c->k_size & 0x3ffU, 10);
            put_bits(word, &bit, (uint64_t)c->layer_type & 0x7U, 3);
            put_bits(word, &bit, (uint64_t)c->layer_last & 0x1U, 1);
            put_bits(word, &bit, (uint64_t)c->layer_valid & 0x1U, 1);
        }
        fprintf(fp, "%015llx%016llx%016llx%016llx\n",
                (unsigned long long)(word[3] & 0x0fffffffffffffffULL), (unsigned long long)word[2],
                (unsigned long long)word[1], (unsigned long long)word[0]);
    }
    fclose(fp);
}

static int ensure_dir(const char *path)
{
    if (mkdir(path, 0775) == 0) return 0;
    return 0; // Existing directory is fine for this simulation dump.
}

static void make_path(char *dst, size_t n, const char *dir, const char *name)
{
    snprintf(dst, n, "%s/%s", dir, name);
}

static void fill_layer_cfg(layer_cfg_dump_t *cfg,
                           const qf_op_t *op,
                           const qf_op_t *resop,
                           int act_base,
                           int wgt_base,
                           int out_base,
                           int residual_base,
                           int layer_last)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->layer_valid = 1;
    cfg->layer_last = layer_last;
    cfg->k_size = op->in_c;
    cfg->m_size = op->type == QF_OP_LINEAR ? 1 : op_out_h(op) * op_out_w(op);
    cfg->n_size = op->out_c;
    cfg->act_base = act_base;
    cfg->wgt_base = wgt_base;
    cfg->out_base = out_base;
    cfg->residual_en = resop != NULL;
    cfg->residual_base = resop ? residual_base : 0;
    cfg->ifmap_size_code = op->type == QF_OP_LINEAR ? 0 : ifmap_size_code(op->in_h);
    cfg->num_filter_code = num_filter_code(op->out_c);
    cfg->stride = op->stride_h == 2;
    cfg->pad = (op->pad_h != 0) || (op->pad_w != 0);
    cfg->pad_value = -op->in_zero_point;
    cfg->mode = resop ? 2 : (op->mode == QF_MODE_PRELU ? 1 : 0);
    cfg->output_zero_point = resop ? -resop->out_zero_point :
                             (op->type == QF_OP_LINEAR ? LINEAR_FC_OUTPUT_ZERO_POINT :
                              op->out_zero_point_add);
    cfg->bias_base = op->type == QF_OP_LINEAR ? LINEAR_FC_PARAM_BASE : op->param_off;
    cfg->requant_mult_base = cfg->bias_base;
    cfg->requant_shift_base = cfg->bias_base;
    cfg->prelu_mult_base = cfg->bias_base;
    cfg->prelu_shift_base = cfg->bias_base;
    cfg->residual_mult_base = cfg->bias_base;
    cfg->residual_shift_base = cfg->bias_base;
    cfg->residual_zero_point_base = cfg->bias_base;

    if (op->type == QF_OP_LINEAR) cfg->layer_type = 4;          // LY_FC
    else if (is_dw(op) && op->kh == 7) cfg->layer_type = 6;     // LY_GDCONV7X7
    else if (is_dw(op)) cfg->layer_type = 2;                    // LY_DWCONV3X3
    else if (op->kh == 3 && op->kw == 3) cfg->layer_type = 5;   // LY_CONV3X3
    else cfg->layer_type = 1;                                   // LY_CONV1X1
}

static void set_lane(word128_t *word, int lane, int8_t value)
{
    uint64_t byte = (uint8_t)value;
    if (lane < 8) word->lo |= byte << (lane * 8);
    else word->hi |= byte << ((lane - 8) * 8);
}

static void pack_activation(word128_t *mem, int base, const int8_t *act, int h, int w, int c)
{
    int tiles = (c + LANES - 1) / LANES;
    for (int x = 0; x < h; x++) {
        for (int y = 0; y < w; y++) {
            for (int t = 0; t < tiles; t++) {
                word128_t word = {0, 0};
                for (int lane = 0; lane < LANES; lane++) {
                    int ch = t * LANES + lane;
                    if (ch < c) {
                        set_lane(&word, lane, act[(x * w + y) * c + ch]);
                    }
                }
                mem[base + (x * w + y) * tiles + t] = word;
            }
        }
    }
}

static void pack_conv1x1_weight(word128_t *mem, int base, const qf_op_t *op)
{
    const int8_t *w = qf_weight + op->weight_off;
    int tiles = op->out_c / LANES;
    for (int ic = 0; ic < op->in_c; ic++) {
        for (int t = 0; t < tiles; t++) {
            word128_t word = {0, 0};
            for (int lane = 0; lane < LANES; lane++) {
                int oc = t * LANES + lane;
                set_lane(&word, lane, w[oc * op->in_c + ic]);
            }
            mem[base + ic * tiles + t] = word;
        }
    }
}

static void pack_dw_weight(word128_t *mem, int base, const qf_op_t *op)
{
    const int8_t *w = qf_weight + op->weight_off;
    int tiles = op->out_c / LANES;
    for (int pos = 0; pos < op->kh * op->kw; pos++) {
        for (int t = 0; t < tiles; t++) {
            word128_t word = {0, 0};
            for (int lane = 0; lane < LANES; lane++) {
                int ch = t * LANES + lane;
                set_lane(&word, lane, w[ch * op->kh * op->kw + pos]);
            }
            mem[base + pos * tiles + t] = word;
        }
    }
}

static void pack_conv3x3_weight(word128_t *mem, int base, const qf_op_t *op)
{
    const int8_t *w = qf_weight + op->weight_off;
    int oc_words = op->out_c / LANES;
    for (int ic = 0; ic < op->in_c; ic++) {
        for (int pos = 0; pos < op->kh * op->kw; pos++) {
            int ky = pos / op->kw;
            int kx = pos % op->kw;
            for (int t = 0; t < oc_words; t++) {
                word128_t word = {0, 0};
                for (int lane = 0; lane < LANES; lane++) {
                    int oc = t * LANES + lane;
                    int w_idx = ((oc * op->in_c + ic) * op->kh + ky) * op->kw + kx;
                    set_lane(&word, lane, w[w_idx]);
                }
                mem[base + (ic * op->kh * op->kw + pos) * oc_words + t] = word;
            }
        }
    }
}

static void pack_linear_weight(word128_t *mem, int base, const qf_op_t *op)
{
    const int8_t *w = qf_weight + op->weight_off;
    int tiles = op->out_c / LANES;
    for (int ic = 0; ic < op->in_c; ic++) {
        for (int t = 0; t < tiles; t++) {
            word128_t word = {0, 0};
            for (int lane = 0; lane < LANES; lane++) {
                int oc = t * LANES + lane;
                set_lane(&word, lane, w[oc * op->in_c + ic]);
            }
            mem[base + ic * tiles + t] = word;
        }
    }
}

static void run_residual_float(const qf_op_t *op, const int8_t *main_in, const int8_t *res_in, int8_t *out)
{
    int total = op->in_h * op->in_w * op->in_c;
    for (int i = 0; i < total; i++) {
        float x = ((float)main_in[i] + op->in_zero_point) / op->in_scale +
                  ((float)res_in[i] + op->res_zero_point) / op->res_scale;
        int q = (int)lroundf(x * op->out_scale - op->out_zero_point);
        if (q > 127) q = 127;
        if (q < -128) q = -128;
        out[i] = (int8_t)q;
    }
}

static void run_conv_model(const qf_op_t *op, const int8_t *in, int8_t *out)
{
    const int8_t *w = qf_weight + op->weight_off;
    const int64_t *bias = qf_bias + op->bias_off;
    const int32_t *mult = qf_mult + op->param_off;
    const int32_t *prelu_mult = qf_prelu_mult + op->param_off;
    const int *shift = qf_shift + op->param_off;
    const int *prelu_shift = qf_prelu_shift + op->param_off;
    int out_h = op_out_h(op);
    int out_w = op_out_w(op);
    int depthwise = is_dw(op);

    for (int oh = 0; oh < out_h; oh++) {
        for (int ow = 0; ow < out_w; ow++) {
            for (int oc = 0; oc < op->out_c; oc++) {
                int64_t acc = 0;
                int ic0 = depthwise ? oc : 0;
                int ic1 = depthwise ? oc + 1 : op->in_c;
                for (int ic = ic0; ic < ic1; ic++) {
                    for (int ky = 0; ky < op->kh; ky++) {
                        int ih = oh * op->stride_h + ky - op->pad_h;
                        for (int kx = 0; kx < op->kw; kx++) {
                            int iw = ow * op->stride_w + kx - op->pad_w;
                            int8_t iv = (ih < 0 || ih >= op->in_h || iw < 0 || iw >= op->in_w)
                                             ? (int8_t)(-op->in_zero_point)
                                             : in[(ih * op->in_w + iw) * op->in_c + ic];
                            int wi = depthwise ? oc * op->kh * op->kw + ky * op->kw + kx
                                               : ((oc * op->in_c + ic) * op->kh + ky) * op->kw + kx;
                            acc += (int64_t)iv * w[wi];
                        }
                    }
                }
                int64_t work = (acc << QF_BIAS_SHIFT) + bias[oc];
                if (op->mode == QF_MODE_PRELU && work < 0) {
                    work = round_shift_i64(work * (int64_t)prelu_mult[oc], prelu_shift[oc]);
                }
                out[(oh * out_w + ow) * op->out_c + oc] =
                    clamp_i8(round_shift_i64(work * (int64_t)mult[oc], shift[oc] + QF_BIAS_SHIFT) +
                             op->out_zero_point_add);
            }
        }
    }
}

static void compute_fused_params(const qf_op_t *conv, const qf_op_t *resop,
                                 int32_t *mult, int *shift, int32_t *res_mult,
                                 int *res_shift, int64_t *res_zp)
{
    double real[1024];
    double res_real[1024];
    for (int oc = 0; oc < conv->out_c; oc++) {
        double old_real = (double)qf_mult[conv->param_off + oc] /
                          (double)((int64_t)1 << qf_shift[conv->param_off + oc]);
        real[oc] = old_real * ((double)resop->out_scale / (double)conv->out_scale);
    }
    int common_shift = choose_common_shift_double(real, conv->out_c);
    for (int oc = 0; oc < conv->out_c; oc++) {
        mult[oc] = (int32_t)llround(real[oc] * (double)((int64_t)1 << common_shift));
        shift[oc] = common_shift;
        res_real[oc] = (double)resop->out_scale / ((double)resop->res_scale * real[oc]);
    }

    int rshift = choose_common_shift_double(res_real, conv->out_c);
    for (int oc = 0; oc < conv->out_c; oc++) {
        res_mult[oc] = (int32_t)llround(res_real[oc] * (double)((int64_t)1 << rshift));
        res_shift[oc] = rshift;
        res_zp[oc] = resop->res_zero_point;
    }
}

static void run_conv_hw(const qf_op_t *op, const qf_op_t *resop, const int8_t *in,
                        const int8_t *residual, int8_t *out, const int32_t *mult_override,
                        const int *shift_override, const int32_t *res_mult,
                        const int *res_shift, const int64_t *res_zp)
{
    const int8_t *w = qf_weight + op->weight_off;
    const int64_t *bias = qf_bias + op->bias_off;
    const int32_t *mult = mult_override ? mult_override : qf_mult + op->param_off;
    const int *shift = shift_override ? shift_override : qf_shift + op->param_off;
    const int32_t *prelu_mult = qf_prelu_mult + op->param_off;
    const int *prelu_shift = qf_prelu_shift + op->param_off;
    int out_h = op_out_h(op);
    int out_w = op_out_w(op);
    int depthwise = is_dw(op);
    int out_zp_add = resop ? -resop->out_zero_point : op->out_zero_point_add;

    for (int oh = 0; oh < out_h; oh++) {
        for (int ow = 0; ow < out_w; ow++) {
            for (int oc = 0; oc < op->out_c; oc++) {
                int64_t acc = 0;
                int ic0 = depthwise ? oc : 0;
                int ic1 = depthwise ? oc + 1 : op->in_c;
                for (int ic = ic0; ic < ic1; ic++) {
                    for (int ky = 0; ky < op->kh; ky++) {
                        int ih = oh * op->stride_h + ky - op->pad_h;
                        for (int kx = 0; kx < op->kw; kx++) {
                            int iw = ow * op->stride_w + kx - op->pad_w;
                            int8_t iv = (ih < 0 || ih >= op->in_h || iw < 0 || iw >= op->in_w)
                                             ? (int8_t)(-op->in_zero_point)
                                             : in[(ih * op->in_w + iw) * op->in_c + ic];
                            int wi = depthwise ? oc * op->kh * op->kw + ky * op->kw + kx
                                               : ((oc * op->in_c + ic) * op->kh + ky) * op->kw + kx;
                            acc += (int64_t)iv * w[wi];
                        }
                    }
                }
                int64_t work = (acc << QF_BIAS_SHIFT) + bias[oc];
                if (resop) {
                    int64_t centered = (int64_t)residual[(oh * out_w + ow) * op->out_c + oc] + res_zp[oc];
                    int64_t scaled = round_shift_i64(centered * (int64_t)res_mult[oc], res_shift[oc]);
                    work += scaled << QF_BIAS_SHIFT;
                } else if (op->mode == QF_MODE_PRELU && work < 0) {
                    work = round_shift_i64(work * (int64_t)prelu_mult[oc], prelu_shift[oc]);
                }
                out[(oh * out_w + ow) * op->out_c + oc] =
                    clamp_i8(round_shift_i64(work * (int64_t)mult[oc], shift[oc] + QF_BIAS_SHIFT) +
                             out_zp_add);
            }
        }
    }
}

static void run_linear_hw_i8(const qf_op_t *op, const int8_t *in, int8_t *out)
{
    const int8_t *w = qf_weight + op->weight_off;
    for (int oc = 0; oc < op->out_c; oc++) {
        int64_t acc = 0;
        for (int ic = 0; ic < op->in_c; ic++) {
            acc += (int64_t)in[ic] * w[oc * op->in_c + ic];
        }
        int64_t work = acc << QF_BIAS_SHIFT;
        out[oc] = clamp_i8(round_shift_i64(work * (int64_t)LINEAR_FC_REQUANT_MULT,
                                          LINEAR_FC_REQUANT_SHIFT + QF_BIAS_SHIFT) +
                           LINEAR_FC_OUTPUT_ZERO_POINT);
    }
}

static void dump_params(const char *dir, const hw_layer_t *layers, int n_layers)
{
    int64_t *bias = calloc(9792, sizeof(int64_t));
    int32_t *mult = calloc(9792, sizeof(int32_t));
    int *shift = calloc(9792, sizeof(int));
    int32_t *prelu_mult = calloc(9792, sizeof(int32_t));
    int *prelu_shift = calloc(9792, sizeof(int));
    int32_t *res_mult = calloc(9792, sizeof(int32_t));
    int *res_shift = calloc(9792, sizeof(int));
    int64_t *res_zp = calloc(9792, sizeof(int64_t));
    char path[512];

    for (int i = 0; i < 9792; i++) {
        bias[i] = qf_bias[i];
        mult[i] = qf_mult[i];
        shift[i] = qf_shift[i];
        prelu_mult[i] = qf_prelu_mult[i];
        prelu_shift[i] = qf_prelu_shift[i];
        res_mult[i] = 1;
        res_shift[i] = 0;
        res_zp[i] = 0;
    }

    for (int li = 0; li < n_layers; li++) {
        if (qf_ops[layers[li].conv_op].type == QF_OP_LINEAR) {
            const qf_op_t *fc = &qf_ops[layers[li].conv_op];
            for (int oc = 0; oc < fc->out_c; oc++) {
                int idx = LINEAR_FC_PARAM_BASE + oc;
                bias[idx] = 0;
                mult[idx] = LINEAR_FC_REQUANT_MULT;
                shift[idx] = LINEAR_FC_REQUANT_SHIFT;
            }
        }
        if (layers[li].residual_op >= 0) {
            const qf_op_t *conv = &qf_ops[layers[li].conv_op];
            const qf_op_t *resop = &qf_ops[layers[li].residual_op];
            int32_t fm[1024], rm[1024];
            int fs[1024], rs[1024];
            int64_t rz[1024];
            compute_fused_params(conv, resop, fm, fs, rm, rs, rz);
            for (int oc = 0; oc < conv->out_c; oc++) {
                int idx = conv->param_off + oc;
                mult[idx] = fm[oc];
                shift[idx] = fs[oc];
                res_mult[idx] = rm[oc];
                res_shift[idx] = rs[oc];
                res_zp[idx] = rz[oc];
            }
        }
    }

    make_path(path, sizeof(path), dir, "quant_param_bias.hex"); write_hex64(path, bias, 9792);
    make_path(path, sizeof(path), dir, "quant_param_requant_mult.hex"); write_hex32(path, mult, 9792);
    make_path(path, sizeof(path), dir, "quant_param_requant_shift.hex"); write_hex6(path, shift, 9792);
    make_path(path, sizeof(path), dir, "quant_param_prelu_mult.hex"); write_hex32(path, prelu_mult, 9792);
    make_path(path, sizeof(path), dir, "quant_param_prelu_shift.hex"); write_hex6(path, prelu_shift, 9792);
    make_path(path, sizeof(path), dir, "quant_param_residual_mult.hex"); write_hex32(path, res_mult, 9792);
    make_path(path, sizeof(path), dir, "quant_param_residual_shift.hex"); write_hex6(path, res_shift, 9792);
    make_path(path, sizeof(path), dir, "quant_param_residual_zero_point.hex"); write_hex64(path, res_zp, 9792);

    free(bias); free(mult); free(shift); free(prelu_mult); free(prelu_shift);
    free(res_mult); free(res_shift); free(res_zp);
}

static void run_prefix(int end_exclusive, int8_t *cur, int8_t *nxt, int8_t *res, int8_t *wanted_res)
{
    memcpy(cur, qf_input, QF_INPUT_SIZE);
    for (int i = 0; i < end_exclusive; i++) {
        const qf_op_t *op = &qf_ops[i];
        if (op->type == QF_OP_SAVE_RES) {
            memcpy(res, cur, (size_t)op->in_h * op->in_w * op->in_c);
            if (wanted_res) memcpy(wanted_res, res, (size_t)op->in_h * op->in_w * op->in_c);
        } else if (op->type == QF_OP_CONV) {
            run_conv_model(op, cur, nxt);
            int8_t *tmp = cur; cur = nxt; nxt = tmp;
        } else if (op->type == QF_OP_RES_ADD) {
            run_residual_float(op, cur, res, nxt);
            int8_t *tmp = cur; cur = nxt; nxt = tmp;
        }
    }
}

static void dump_sequence(const char *dir, int profile)
{
    static const hw_layer_t seq0[] = {
        {4, -1, AO_BASE0, WGT_BASE0, AO_BASE1, 0},
        {6, -1, AO_BASE1, WGT_BASE1, AO_BASE2, 0},
        {7, -1, AO_BASE2, WGT_BASE2, AO_BASE3, 0},
        {8,  9, AO_BASE3, WGT_BASE3, AO_BASE4, AO_BASE1},
    };
    static const hw_layer_t seq1[] = {
        {13, 14, AO_BASE0, WGT_BASE0, AO_BASE1, AO_BASE2},
        {16, -1, AO_BASE1, WGT_BASE1, AO_BASE2, 0},
        {17, -1, AO_BASE2, WGT_BASE2, AO_BASE3, 0},
        {18, 19, AO_BASE3, WGT_BASE3, AO_BASE4, AO_BASE1},
    };
    static const hw_layer_t seq2[] = {
        {3, -1, AO_BASE0, WGT_BASE0, AO_BASE3, 0},
        {4, -1, AO_BASE3, WGT_BASE1, AO_BASE4, 0},
    };
    static const hw_layer_t seq3[] = {
        {0, -1, AO_BASE0, WGT_BASE0, AO_BASE2, 0},
        {1, -1, AO_BASE2, WGT_BASE1, AO_BASE4, 0},
    };
    static const hw_layer_t seq4[] = {
        {72, -1, AO_BASE0, WGT_BASE0, AO_BASE3, 0},
        {73, -1, AO_BASE3, WGT_BASE1, AO_BASE4, 0},
    };
    const hw_layer_t *layers = profile == 12 ? seq4 :
                               (profile == 10 ? seq3 : (profile == 8 ? seq2 : (profile == 6 ? seq1 : seq0)));
    int n_layers = (profile == 8 || profile == 10 || profile == 12) ? 2 : 4;
    int start_op = profile == 12 ? 72 : (profile == 10 ? 0 : (profile == 8 ? 3 : (profile == 6 ? 13 : 4)));
    int save_for_input = profile == 6 ? 10 : -1;
    word128_t *ao = calloc(AO_DEPTH, sizeof(word128_t));
    word128_t *wgt = calloc(WGT_DEPTH, sizeof(word128_t));
    word128_t *gold = calloc(AO_DEPTH, sizeof(word128_t));
    layer_cfg_dump_t cfg[FULL_CFG_DEPTH];
    int8_t *buf0 = calloc(QF_MAX_ACT, 1);
    int8_t *buf1 = calloc(QF_MAX_ACT, 1);
    int8_t *res = calloc(QF_MAX_ACT, 1);
    int8_t *initial = calloc(QF_MAX_ACT, 1);
    int8_t *initial_res = calloc(QF_MAX_ACT, 1);
    char path[512];

    (void)save_for_input;
    memset(cfg, 0, sizeof(cfg));
    ensure_dir(dir);
    run_prefix(start_op, buf0, buf1, res, profile == 6 ? initial_res : NULL);
    // run_prefix swaps internally by local variables, so regenerate simply by
    // walking with explicit current pointers for the chosen cut.
    int8_t *cur = buf0, *nxt = buf1;
    memcpy(cur, qf_input, QF_INPUT_SIZE);
    for (int i = 0; i < start_op; i++) {
        const qf_op_t *op = &qf_ops[i];
        if (op->type == QF_OP_SAVE_RES) {
            memcpy(res, cur, (size_t)op->in_h * op->in_w * op->in_c);
            if (profile == 6 && i == 10) memcpy(initial_res, res, (size_t)op->in_h * op->in_w * op->in_c);
        } else if (op->type == QF_OP_CONV) {
            run_conv_model(op, cur, nxt);
            int8_t *tmp = cur; cur = nxt; nxt = tmp;
        } else if (op->type == QF_OP_RES_ADD) {
            run_residual_float(op, cur, res, nxt);
            int8_t *tmp = cur; cur = nxt; nxt = tmp;
        }
    }
    memcpy(initial, cur, (size_t)qf_ops[start_op].in_h * qf_ops[start_op].in_w * qf_ops[start_op].in_c);

    pack_activation(ao, AO_BASE0, initial, qf_ops[start_op].in_h, qf_ops[start_op].in_w, qf_ops[start_op].in_c);
    if (profile == 6) {
        pack_activation(ao, AO_BASE2, initial_res, qf_ops[14].in_h, qf_ops[14].in_w, qf_ops[14].in_c);
    }

    cur = initial;
    nxt = buf1;
    int8_t *seq_res0 = profile == 6 ? initial_res : NULL;
    int8_t *saved_after_l0 = buf0;
    for (int li = 0; li < n_layers; li++) {
        const qf_op_t *op = &qf_ops[layers[li].conv_op];
        const qf_op_t *resop = layers[li].residual_op >= 0 ? &qf_ops[layers[li].residual_op] : NULL;
        int32_t fm[1024] = {0}, rm[1024] = {0};
        int fs[1024] = {0}, rs[1024] = {0};
        int64_t rz[1024] = {0};
        const int8_t *res_in = NULL;

        if (op->type == QF_OP_LINEAR) pack_linear_weight(wgt, layers[li].wgt_base, op);
        else if (is_dw(op)) pack_dw_weight(wgt, layers[li].wgt_base, op);
        else if (op->kh == 3 && op->kw == 3) pack_conv3x3_weight(wgt, layers[li].wgt_base, op);
        else pack_conv1x1_weight(wgt, layers[li].wgt_base, op);

        fill_layer_cfg(&cfg[li], op, resop, layers[li].act_base, layers[li].wgt_base,
                       layers[li].out_base, layers[li].residual_base, li == n_layers - 1);

        if (resop) {
            compute_fused_params(op, resop, fm, fs, rm, rs, rz);
            res_in = (profile == 6 && li == 0) ? seq_res0 : saved_after_l0;
        }
        if (op->type == QF_OP_LINEAR) {
            run_linear_hw_i8(op, cur, nxt);
        } else {
            run_conv_hw(op, resop, cur, res_in, nxt, resop ? fm : NULL, resop ? fs : NULL, rm, rs, rz);
        }
        if (li == 0) {
            size_t saved_size = (op->type == QF_OP_LINEAR) ? (size_t)op->out_c :
                                (size_t)op_out_h(op) * op_out_w(op) * op->out_c;
            memcpy(saved_after_l0, nxt, saved_size);
        }
        int8_t *tmp = cur; cur = nxt; nxt = tmp;
    }

    const qf_op_t *last = &qf_ops[layers[n_layers - 1].conv_op];
    if (last->type == QF_OP_LINEAR) {
        pack_activation(gold, AO_BASE4, cur, 1, 1, last->out_c);
    } else {
        pack_activation(gold, AO_BASE4, cur, op_out_h(last), op_out_w(last), last->out_c);
    }
    dump_params(dir, layers, n_layers);

    make_path(path, sizeof(path), dir, "layer_config.hex"); write_layer_config_hex(path, cfg, n_layers);
    make_path(path, sizeof(path), dir, "system_2_2_ao_init.hex"); write_mem_hex(path, ao, AO_DEPTH);
    make_path(path, sizeof(path), dir, "system_2_2_wgt_init.hex"); write_mem_hex(path, wgt, WGT_DEPTH);
    make_path(path, sizeof(path), dir, "system_2_2_golden.hex"); write_mem_hex(path, gold, AO_DEPTH);
    printf("dumped system_2_2 profile=%d dir=%s final_base=%d\n", profile, dir, AO_BASE4);

    free(ao); free(wgt); free(gold); free(buf0); free(buf1); free(res); free(initial); free(initial_res);
}

static void dump_full_model_hw_spec(const char *dir)
{
    word128_t *ao = calloc(AO_DEPTH, sizeof(word128_t));
    word128_t *wgt = calloc(65536, sizeof(word128_t));
    word128_t *gold = calloc(AO_DEPTH, sizeof(word128_t));
    int8_t *buf0 = calloc(QF_MAX_ACT, 1);
    int8_t *buf1 = calloc(QF_MAX_ACT, 1);
    int8_t *res = calloc(QF_MAX_ACT, 1);
    int8_t *cur = buf0;
    int8_t *nxt = buf1;
    int cur_base = FULL_AO_BASE0;
    int next_base = FULL_AO_BASE1;
    int saved_res_base = 0;
    int residual_live = 0;
    layer_cfg_dump_t cfg[FULL_CFG_DEPTH];
    hw_layer_t hw_layers[FULL_CFG_DEPTH];
    int n_cfg = 0;
    char path[512];

    memset(cfg, 0, sizeof(cfg));
    memset(hw_layers, 0, sizeof(hw_layers));
    ensure_dir(dir);

    memcpy(cur, qf_input, QF_INPUT_SIZE);
    pack_activation(ao, cur_base, cur, 112, 112, 3);

    for (int op_idx = 0; op_idx < QF_NUM_OPS; op_idx++) {
        const qf_op_t *op = &qf_ops[op_idx];
        if (op->type == QF_OP_SAVE_RES) {
            size_t bytes = (size_t)op->in_h * op->in_w * op->in_c;
            memcpy(res, cur, bytes);
            saved_res_base = cur_base;
            residual_live = 1;
            continue;
        }
        if (op->type != QF_OP_CONV && op->type != QF_OP_LINEAR) {
            continue;
        }

        int residual_op = -1;
        if ((op_idx + 1) < QF_NUM_OPS && qf_ops[op_idx + 1].type == QF_OP_RES_ADD) {
            residual_op = op_idx + 1;
        }
        if (op->type == QF_OP_LINEAR) {
            next_base = AO_BASE4;
        } else if (cur_base != FULL_AO_BASE0 && (!residual_live || saved_res_base != FULL_AO_BASE0)) {
            next_base = FULL_AO_BASE0;
        } else if (cur_base != FULL_AO_BASE1 && (!residual_live || saved_res_base != FULL_AO_BASE1)) {
            next_base = FULL_AO_BASE1;
        } else {
            next_base = FULL_AO_RES_BASE;
        }

        if (op->type == QF_OP_LINEAR) {
            pack_linear_weight(wgt, op->weight_off / LANES, op);
            run_linear_hw_i8(op, cur, nxt);
        } else {
            int32_t fm[1024] = {0}, rm[1024] = {0};
            int fs[1024] = {0}, rs[1024] = {0};
            int64_t rz[1024] = {0};
            const qf_op_t *resop = residual_op >= 0 ? &qf_ops[residual_op] : NULL;

            if (is_dw(op)) pack_dw_weight(wgt, op->weight_off / LANES, op);
            else if (op->kh == 3 && op->kw == 3) pack_conv3x3_weight(wgt, op->weight_off / LANES, op);
            else pack_conv1x1_weight(wgt, op->weight_off / LANES, op);

            if (resop) {
                compute_fused_params(op, resop, fm, fs, rm, rs, rz);
            }
            run_conv_hw(op, resop, cur, resop ? res : NULL, nxt,
                        resop ? fm : NULL, resop ? fs : NULL, rm, rs, rz);
        }

        if (n_cfg >= FULL_CFG_DEPTH) {
            fprintf(stderr, "too many hardware layers for FULL_CFG_DEPTH=%d\n", FULL_CFG_DEPTH);
            exit(1);
        }

        cfg[n_cfg].layer_valid = 1;
        cfg[n_cfg].layer_last = 0;
        cfg[n_cfg].k_size = op->in_c;
        cfg[n_cfg].m_size = op->type == QF_OP_LINEAR ? 1 : op_out_h(op) * op_out_w(op);
        cfg[n_cfg].n_size = op->out_c;
        cfg[n_cfg].act_base = cur_base;
        cfg[n_cfg].wgt_base = op->weight_off / LANES;
        cfg[n_cfg].out_base = next_base;
        cfg[n_cfg].residual_en = residual_op >= 0;
        cfg[n_cfg].residual_base = residual_op >= 0 ? saved_res_base : 0;
        cfg[n_cfg].ifmap_size_code = op->type == QF_OP_LINEAR ? 0 : ifmap_size_code(op->in_h);
        cfg[n_cfg].num_filter_code = num_filter_code(op->out_c);
        cfg[n_cfg].stride = op->stride_h == 2;
        cfg[n_cfg].pad = (op->pad_h != 0) || (op->pad_w != 0);
        cfg[n_cfg].pad_value = -op->in_zero_point;
        cfg[n_cfg].mode = residual_op >= 0 ? QF_MODE_REQUANT + 2 :
                          (op->mode == QF_MODE_PRELU ? QF_MODE_PRELU : QF_MODE_REQUANT);
        cfg[n_cfg].output_zero_point = residual_op >= 0 ? -qf_ops[residual_op].out_zero_point :
                                        (op->type == QF_OP_LINEAR ? LINEAR_FC_OUTPUT_ZERO_POINT :
                                         op->out_zero_point_add);
        cfg[n_cfg].bias_base = op->type == QF_OP_LINEAR ? LINEAR_FC_PARAM_BASE : op->param_off;
        cfg[n_cfg].requant_mult_base = cfg[n_cfg].bias_base;
        cfg[n_cfg].requant_shift_base = cfg[n_cfg].bias_base;
        cfg[n_cfg].prelu_mult_base = cfg[n_cfg].bias_base;
        cfg[n_cfg].prelu_shift_base = cfg[n_cfg].bias_base;
        cfg[n_cfg].residual_mult_base = cfg[n_cfg].bias_base;
        cfg[n_cfg].residual_shift_base = cfg[n_cfg].bias_base;
        cfg[n_cfg].residual_zero_point_base = cfg[n_cfg].bias_base;

        if (op->type == QF_OP_LINEAR) cfg[n_cfg].layer_type = 4;          // LY_FC
        else if (is_dw(op) && op->kh == 7) cfg[n_cfg].layer_type = 6;     // LY_GDCONV7X7
        else if (is_dw(op)) cfg[n_cfg].layer_type = 2;                    // LY_DWCONV3X3
        else if (op->kh == 3 && op->kw == 3) cfg[n_cfg].layer_type = 5;   // LY_CONV3X3
        else cfg[n_cfg].layer_type = 1;                                   // LY_CONV1X1

        hw_layers[n_cfg].conv_op = op_idx;
        hw_layers[n_cfg].residual_op = residual_op;
        hw_layers[n_cfg].act_base = cur_base;
        hw_layers[n_cfg].wgt_base = cfg[n_cfg].wgt_base;
        hw_layers[n_cfg].out_base = next_base;
        hw_layers[n_cfg].residual_base = cfg[n_cfg].residual_base;
        n_cfg++;

        if (residual_op >= 0) {
            residual_live = 0;
            op_idx++;
        }

        if (op->type == QF_OP_LINEAR) {
            pack_activation(gold, next_base, nxt, 1, 1, op->out_c);
        }

        int8_t *tmp = cur; cur = nxt; nxt = tmp;
        cur_base = next_base;
    }

    if (n_cfg > 0) {
        cfg[n_cfg - 1].layer_last = 1;
    }

    dump_params(dir, hw_layers, n_cfg);
    make_path(path, sizeof(path), dir, "layer_config.hex"); write_layer_config_hex(path, cfg, n_cfg);
    make_path(path, sizeof(path), dir, "system_2_2_ao_init.hex"); write_mem_hex(path, ao, AO_DEPTH);
    make_path(path, sizeof(path), dir, "system_2_2_wgt_init.hex"); write_mem_hex(path, wgt, 65536);
    make_path(path, sizeof(path), dir, "system_2_2_golden.hex"); write_mem_hex(path, gold, AO_DEPTH);
    printf("dumped full_model_hw_spec layers=%d dir=%s final_base=%d\n", n_cfg, dir, cur_base);

    free(ao); free(wgt); free(gold); free(buf0); free(buf1); free(res);
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "generated/system_2_2_seq0";
    int profile = argc > 2 ? atoi(argv[2]) : 5;
    if (profile == FULL_LAYER_PROFILE) {
        dump_full_model_hw_spec(dir);
        return 0;
    }
    if (profile != 5 && profile != 6 && profile != 8 && profile != 10 && profile != 12) {
        fprintf(stderr, "profile must be 5, 6, 8, 10, 12, or 13\n");
        return 1;
    }
    dump_sequence(dir, profile);
    return 0;
}
