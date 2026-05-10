#ifndef QFACE_MODEL_H
#define QFACE_MODEL_H

#include <stdint.h>

#define QF_MODE_REQUANT 0
#define QF_MODE_PRELU 1

#define QF_OP_CONV 0
#define QF_OP_SAVE_RES 1
#define QF_OP_RES_ADD 2
#define QF_OP_LINEAR 3

#define QF_OUTPUT_I8 0
#define QF_OUTPUT_EMBED 1

typedef struct {
    int type;
    int mode;
    int in_h;
    int in_w;
    int in_c;
    int out_c;
    int kh;
    int kw;
    int stride_h;
    int stride_w;
    int pad_h;
    int pad_w;
    int groups;
    int weight_off;
    int bias_off;
    int param_off;
    int out_zero_point_add;
    float in_scale;
    int in_zero_point;
    float out_scale;
    int out_zero_point;
    float res_scale;
    int res_zero_point;
} qf_op_t;

typedef struct {
    int h;
    int w;
    int c;
} qf_tensor_shape_t;

int qface_run_embedding(const int8_t *input_nhwc, float *embedding);
int qface_run_i8(const int8_t *input_nhwc, int8_t *output_nhwc, qf_tensor_shape_t *shape);
int qface_compare_embedding(const float *embedding, float *mae, float *rmse, float *max_abs, float *cosine);
int qface_compare_i8(const int8_t *output_nhwc, int *mismatches);

#endif
