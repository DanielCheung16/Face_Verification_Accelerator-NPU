#ifndef QFACE_PARAMS_H
#define QFACE_PARAMS_H
#include <stdint.h>
#include "qface_model.h"
#define QF_BIAS_SHIFT 16
#define QF_NUM_OPS 74
#define QF_INPUT_SIZE 37632
#define QF_INPUT_H 112
#define QF_INPUT_W 112
#define QF_INPUT_C 3
#define QF_OUTPUT_H 1
#define QF_OUTPUT_W 1
#define QF_OUTPUT_C 128
#define QF_OUTPUT_KIND QF_OUTPUT_EMBED
#define QF_MAX_ACT 6422528
#define QF_EMBED 128
#define QF_GOLDEN_I8_SIZE 0
extern const qf_op_t qf_ops[74];
extern const int8_t qf_input[37632];
extern const int8_t qf_weight[976000];
extern const int64_t qf_bias[9792];
extern const int32_t qf_mult[9792];
extern const int qf_shift[9792];
extern const int32_t qf_prelu_mult[9792];
extern const int qf_prelu_shift[9792];
extern const float qf_final_scale[128];
extern const float qf_final_bias[128];
extern const float qf_true_embedding[128];
extern const int8_t qf_true_output_i8[1];
#endif
