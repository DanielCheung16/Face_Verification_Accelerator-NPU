#include "qface_model.h"
#include "qface_params.h"

#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    if (QF_OUTPUT_KIND == QF_OUTPUT_EMBED) {
        float *embedding = (float *)calloc(QF_EMBED, sizeof(float));
        if (!embedding) {
            fprintf(stderr, "allocation failed\n");
            return 1;
        }
        if (qface_run_embedding(qf_input, embedding) != 0) {
            fprintf(stderr, "qface_run_embedding failed\n");
            free(embedding);
            return 1;
        }
        float mae = 0.0f;
        float rmse = 0.0f;
        float max_abs = 0.0f;
        float cosine = 0.0f;
        qface_compare_embedding(embedding, &mae, &rmse, &max_abs, &cosine);
        printf("qface_c vs QuantFace embedding: mae=%.8f rmse=%.8f max_abs=%.8f cosine=%.8f\n",
               mae, rmse, max_abs, cosine);
        free(embedding);
    } else {
        int8_t *output = (int8_t *)calloc(QF_GOLDEN_I8_SIZE, sizeof(int8_t));
        if (!output) {
            fprintf(stderr, "allocation failed\n");
            return 1;
        }
        qf_tensor_shape_t shape;
        if (qface_run_i8(qf_input, output, &shape) != 0) {
            fprintf(stderr, "qface_run_i8 failed\n");
            free(output);
            return 1;
        }
        int mismatches = 0;
        qface_compare_i8(output, &mismatches);
        printf("qface_c segment output: shape=%dx%dx%d mismatches=%d / %d\n",
               shape.h, shape.w, shape.c, mismatches, QF_GOLDEN_I8_SIZE);
        free(output);
    }
    return 0;
}
