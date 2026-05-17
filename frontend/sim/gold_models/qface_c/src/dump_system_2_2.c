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

static int op_out_h(const qf_op_t *op) { return (op->in_h + 2 * op->pad_h - op->kh) / op->stride_h + 1; }
static int op_out_w(const qf_op_t *op) { return (op->in_w + 2 * op->pad_w - op->kw) / op->stride_w + 1; }
static int is_dw(const qf_op_t *op) { return op->groups == op->in_c && op->out_c == op->in_c; }

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

static int ensure_dir(const char *path)
{
    if (mkdir(path, 0775) == 0) return 0;
    return 0; // Existing directory is fine for this simulation dump.
}

static void make_path(char *dst, size_t n, const char *dir, const char *name)
{
    snprintf(dst, n, "%s/%s", dir, name);
}

static void set_lane(word128_t *word, int lane, int8_t value)
{
    uint64_t byte = (uint8_t)value;
    if (lane < 8) word->lo |= byte << (lane * 8);
    else word->hi |= byte << ((lane - 8) * 8);
}

static void pack_activation(word128_t *mem, int base, const int8_t *act, int h, int w, int c)
{
    int tiles = c / LANES;
    for (int x = 0; x < h; x++) {
        for (int y = 0; y < w; y++) {
            for (int t = 0; t < tiles; t++) {
                word128_t word = {0, 0};
                for (int lane = 0; lane < LANES; lane++) {
                    int ch = t * LANES + lane;
                    set_lane(&word, lane, act[(x * w + y) * c + ch]);
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
                                             ? 0
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
    const hw_layer_t *layers = profile == 6 ? seq1 : seq0;
    int n_layers = 4;
    int start_op = profile == 6 ? 13 : 4;
    int save_for_input = profile == 6 ? 10 : -1;
    word128_t *ao = calloc(AO_DEPTH, sizeof(word128_t));
    word128_t *wgt = calloc(WGT_DEPTH, sizeof(word128_t));
    word128_t *gold = calloc(AO_DEPTH, sizeof(word128_t));
    int8_t *buf0 = calloc(QF_MAX_ACT, 1);
    int8_t *buf1 = calloc(QF_MAX_ACT, 1);
    int8_t *res = calloc(QF_MAX_ACT, 1);
    int8_t *initial = calloc(QF_MAX_ACT, 1);
    int8_t *initial_res = calloc(QF_MAX_ACT, 1);
    char path[512];

    (void)save_for_input;
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

        if (is_dw(op)) pack_dw_weight(wgt, layers[li].wgt_base, op);
        else pack_conv1x1_weight(wgt, layers[li].wgt_base, op);

        if (resop) {
            compute_fused_params(op, resop, fm, fs, rm, rs, rz);
            res_in = (profile == 6 && li == 0) ? seq_res0 : saved_after_l0;
        }
        run_conv_hw(op, resop, cur, res_in, nxt, resop ? fm : NULL, resop ? fs : NULL, rm, rs, rz);
        if (li == 0) {
            memcpy(saved_after_l0, nxt, (size_t)op_out_h(op) * op_out_w(op) * op->out_c);
        }
        int8_t *tmp = cur; cur = nxt; nxt = tmp;
    }

    const qf_op_t *last = &qf_ops[layers[n_layers - 1].conv_op];
    pack_activation(gold, AO_BASE4, cur, op_out_h(last), op_out_w(last), last->out_c);
    dump_params(dir, layers, n_layers);

    make_path(path, sizeof(path), dir, "system_2_2_ao_init.hex"); write_mem_hex(path, ao, AO_DEPTH);
    make_path(path, sizeof(path), dir, "system_2_2_wgt_init.hex"); write_mem_hex(path, wgt, WGT_DEPTH);
    make_path(path, sizeof(path), dir, "system_2_2_golden.hex"); write_mem_hex(path, gold, AO_DEPTH);
    printf("dumped system_2_2 profile=%d dir=%s final_base=%d\n", profile, dir, AO_BASE4);

    free(ao); free(wgt); free(gold); free(buf0); free(buf1); free(res); free(initial); free(initial_res);
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "generated/system_2_2_seq0";
    int profile = argc > 2 ? atoi(argv[2]) : 5;
    if (profile != 5 && profile != 6) {
        fprintf(stderr, "profile must be 5 or 6\n");
        return 1;
    }
    dump_sequence(dir, profile);
    return 0;
}
