# MobileFaceNet W8A8 Layer Shape and Parameter Table

- Model: `pretrained_models/quantface_mobilefacenet_w8a8_real/backbone.pt`
- Input shape: `1x3x112x112`
- Output shape: `1x128`
- Total captured layers: `145`
- Captured parameter elements: `1003136`
- Captured MACs: `220965376`

| index | name | type | input_shape | output_shape | kernel_size | stride | padding | groups | param_numel | macs | weight_bit | activation_bit | note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | conv1.conv | Quant_Conv2d | 1x3x112x112 | 1x64x56x56 | 3x3 | 2x2 | 1x1 | 1 | 1728 | 5419008 | 8 |  |  |
| 1 | conv1.bn | BatchNorm2d | 1x64x56x56 | 1x64x56x56 |  |  |  |  | 128 |  |  |  |  |
| 2 | conv1.prelu | QuantActPreLu | 1x64x56x56 | 1x64x56x56 |  |  |  |  | 64 |  |  | 8 | prelu_then_activation_quant |
| 3 | conv2_dw.conv | Quant_Conv2d | 1x64x56x56 | 1x64x56x56 | 3x3 | 1x1 | 1x1 | 64 | 576 | 1806336 | 8 |  |  |
| 4 | conv2_dw.bn | BatchNorm2d | 1x64x56x56 | 1x64x56x56 |  |  |  |  | 128 |  |  |  |  |
| 5 | conv2_dw.prelu | QuantActPreLu | 1x64x56x56 | 1x64x56x56 |  |  |  |  | 64 |  |  | 8 | prelu_then_activation_quant |
| 6 | conv_23.conv.conv | Quant_Conv2d | 1x64x56x56 | 1x128x56x56 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 25690112 | 8 |  |  |
| 7 | conv_23.conv.bn | BatchNorm2d | 1x128x56x56 | 1x128x56x56 |  |  |  |  | 256 |  |  |  |  |
| 8 | conv_23.conv.prelu | QuantActPreLu | 1x128x56x56 | 1x128x56x56 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 9 | conv_23.conv_dw.conv | Quant_Conv2d | 1x128x56x56 | 1x128x28x28 | 3x3 | 2x2 | 1x1 | 128 | 1152 | 903168 | 8 |  |  |
| 10 | conv_23.conv_dw.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 11 | conv_23.conv_dw.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 12 | conv_23.project.conv | Quant_Conv2d | 1x128x28x28 | 1x64x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 13 | conv_23.project.bn | BatchNorm2d | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 128 |  |  |  |  |
| 14 | conv_3.model.0.0.conv.conv | Quant_Conv2d | 1x64x28x28 | 1x128x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 15 | conv_3.model.0.0.conv.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 16 | conv_3.model.0.0.conv.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 17 | conv_3.model.0.0.conv_dw.conv | Quant_Conv2d | 1x128x28x28 | 1x128x28x28 | 3x3 | 1x1 | 1x1 | 128 | 1152 | 903168 | 8 |  |  |
| 18 | conv_3.model.0.0.conv_dw.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 19 | conv_3.model.0.0.conv_dw.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 20 | conv_3.model.0.0.project.conv | Quant_Conv2d | 1x128x28x28 | 1x64x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 21 | conv_3.model.0.0.project.bn | BatchNorm2d | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 128 |  |  |  |  |
| 22 | conv_3.model.0.1 | QuantAct | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 23 | conv_3.model.1.0.conv.conv | Quant_Conv2d | 1x64x28x28 | 1x128x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 24 | conv_3.model.1.0.conv.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 25 | conv_3.model.1.0.conv.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 26 | conv_3.model.1.0.conv_dw.conv | Quant_Conv2d | 1x128x28x28 | 1x128x28x28 | 3x3 | 1x1 | 1x1 | 128 | 1152 | 903168 | 8 |  |  |
| 27 | conv_3.model.1.0.conv_dw.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 28 | conv_3.model.1.0.conv_dw.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 29 | conv_3.model.1.0.project.conv | Quant_Conv2d | 1x128x28x28 | 1x64x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 30 | conv_3.model.1.0.project.bn | BatchNorm2d | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 128 |  |  |  |  |
| 31 | conv_3.model.1.1 | QuantAct | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 32 | conv_3.model.2.0.conv.conv | Quant_Conv2d | 1x64x28x28 | 1x128x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 33 | conv_3.model.2.0.conv.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 34 | conv_3.model.2.0.conv.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 35 | conv_3.model.2.0.conv_dw.conv | Quant_Conv2d | 1x128x28x28 | 1x128x28x28 | 3x3 | 1x1 | 1x1 | 128 | 1152 | 903168 | 8 |  |  |
| 36 | conv_3.model.2.0.conv_dw.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 37 | conv_3.model.2.0.conv_dw.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 38 | conv_3.model.2.0.project.conv | Quant_Conv2d | 1x128x28x28 | 1x64x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 39 | conv_3.model.2.0.project.bn | BatchNorm2d | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 128 |  |  |  |  |
| 40 | conv_3.model.2.1 | QuantAct | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 41 | conv_3.model.3.0.conv.conv | Quant_Conv2d | 1x64x28x28 | 1x128x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 42 | conv_3.model.3.0.conv.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 43 | conv_3.model.3.0.conv.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 44 | conv_3.model.3.0.conv_dw.conv | Quant_Conv2d | 1x128x28x28 | 1x128x28x28 | 3x3 | 1x1 | 1x1 | 128 | 1152 | 903168 | 8 |  |  |
| 45 | conv_3.model.3.0.conv_dw.bn | BatchNorm2d | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 256 |  |  |  |  |
| 46 | conv_3.model.3.0.conv_dw.prelu | QuantActPreLu | 1x128x28x28 | 1x128x28x28 |  |  |  |  | 128 |  |  | 8 | prelu_then_activation_quant |
| 47 | conv_3.model.3.0.project.conv | Quant_Conv2d | 1x128x28x28 | 1x64x28x28 | 1x1 | 1x1 | 0x0 | 1 | 8192 | 6422528 | 8 |  |  |
| 48 | conv_3.model.3.0.project.bn | BatchNorm2d | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 128 |  |  |  |  |
| 49 | conv_3.model.3.1 | QuantAct | 1x64x28x28 | 1x64x28x28 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 50 | conv_34.conv.conv | Quant_Conv2d | 1x64x28x28 | 1x256x28x28 | 1x1 | 1x1 | 0x0 | 1 | 16384 | 12845056 | 8 |  |  |
| 51 | conv_34.conv.bn | BatchNorm2d | 1x256x28x28 | 1x256x28x28 |  |  |  |  | 512 |  |  |  |  |
| 52 | conv_34.conv.prelu | QuantActPreLu | 1x256x28x28 | 1x256x28x28 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 53 | conv_34.conv_dw.conv | Quant_Conv2d | 1x256x28x28 | 1x256x14x14 | 3x3 | 2x2 | 1x1 | 256 | 2304 | 451584 | 8 |  |  |
| 54 | conv_34.conv_dw.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 55 | conv_34.conv_dw.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 56 | conv_34.project.conv | Quant_Conv2d | 1x256x14x14 | 1x128x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 57 | conv_34.project.bn | BatchNorm2d | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 256 |  |  |  |  |
| 58 | conv_4.model.0.0.conv.conv | Quant_Conv2d | 1x128x14x14 | 1x256x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 59 | conv_4.model.0.0.conv.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 60 | conv_4.model.0.0.conv.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 61 | conv_4.model.0.0.conv_dw.conv | Quant_Conv2d | 1x256x14x14 | 1x256x14x14 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 451584 | 8 |  |  |
| 62 | conv_4.model.0.0.conv_dw.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 63 | conv_4.model.0.0.conv_dw.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 64 | conv_4.model.0.0.project.conv | Quant_Conv2d | 1x256x14x14 | 1x128x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 65 | conv_4.model.0.0.project.bn | BatchNorm2d | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 256 |  |  |  |  |
| 66 | conv_4.model.0.1 | QuantAct | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 67 | conv_4.model.1.0.conv.conv | Quant_Conv2d | 1x128x14x14 | 1x256x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 68 | conv_4.model.1.0.conv.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 69 | conv_4.model.1.0.conv.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 70 | conv_4.model.1.0.conv_dw.conv | Quant_Conv2d | 1x256x14x14 | 1x256x14x14 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 451584 | 8 |  |  |
| 71 | conv_4.model.1.0.conv_dw.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 72 | conv_4.model.1.0.conv_dw.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 73 | conv_4.model.1.0.project.conv | Quant_Conv2d | 1x256x14x14 | 1x128x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 74 | conv_4.model.1.0.project.bn | BatchNorm2d | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 256 |  |  |  |  |
| 75 | conv_4.model.1.1 | QuantAct | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 76 | conv_4.model.2.0.conv.conv | Quant_Conv2d | 1x128x14x14 | 1x256x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 77 | conv_4.model.2.0.conv.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 78 | conv_4.model.2.0.conv.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 79 | conv_4.model.2.0.conv_dw.conv | Quant_Conv2d | 1x256x14x14 | 1x256x14x14 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 451584 | 8 |  |  |
| 80 | conv_4.model.2.0.conv_dw.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 81 | conv_4.model.2.0.conv_dw.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 82 | conv_4.model.2.0.project.conv | Quant_Conv2d | 1x256x14x14 | 1x128x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 83 | conv_4.model.2.0.project.bn | BatchNorm2d | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 256 |  |  |  |  |
| 84 | conv_4.model.2.1 | QuantAct | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 85 | conv_4.model.3.0.conv.conv | Quant_Conv2d | 1x128x14x14 | 1x256x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 86 | conv_4.model.3.0.conv.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 87 | conv_4.model.3.0.conv.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 88 | conv_4.model.3.0.conv_dw.conv | Quant_Conv2d | 1x256x14x14 | 1x256x14x14 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 451584 | 8 |  |  |
| 89 | conv_4.model.3.0.conv_dw.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 90 | conv_4.model.3.0.conv_dw.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 91 | conv_4.model.3.0.project.conv | Quant_Conv2d | 1x256x14x14 | 1x128x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 92 | conv_4.model.3.0.project.bn | BatchNorm2d | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 256 |  |  |  |  |
| 93 | conv_4.model.3.1 | QuantAct | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 94 | conv_4.model.4.0.conv.conv | Quant_Conv2d | 1x128x14x14 | 1x256x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 95 | conv_4.model.4.0.conv.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 96 | conv_4.model.4.0.conv.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 97 | conv_4.model.4.0.conv_dw.conv | Quant_Conv2d | 1x256x14x14 | 1x256x14x14 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 451584 | 8 |  |  |
| 98 | conv_4.model.4.0.conv_dw.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 99 | conv_4.model.4.0.conv_dw.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 100 | conv_4.model.4.0.project.conv | Quant_Conv2d | 1x256x14x14 | 1x128x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 101 | conv_4.model.4.0.project.bn | BatchNorm2d | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 256 |  |  |  |  |
| 102 | conv_4.model.4.1 | QuantAct | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 103 | conv_4.model.5.0.conv.conv | Quant_Conv2d | 1x128x14x14 | 1x256x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 104 | conv_4.model.5.0.conv.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 105 | conv_4.model.5.0.conv.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 106 | conv_4.model.5.0.conv_dw.conv | Quant_Conv2d | 1x256x14x14 | 1x256x14x14 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 451584 | 8 |  |  |
| 107 | conv_4.model.5.0.conv_dw.bn | BatchNorm2d | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 512 |  |  |  |  |
| 108 | conv_4.model.5.0.conv_dw.prelu | QuantActPreLu | 1x256x14x14 | 1x256x14x14 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 109 | conv_4.model.5.0.project.conv | Quant_Conv2d | 1x256x14x14 | 1x128x14x14 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 6422528 | 8 |  |  |
| 110 | conv_4.model.5.0.project.bn | BatchNorm2d | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 256 |  |  |  |  |
| 111 | conv_4.model.5.1 | QuantAct | 1x128x14x14 | 1x128x14x14 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 112 | conv_45.conv.conv | Quant_Conv2d | 1x128x14x14 | 1x512x14x14 | 1x1 | 1x1 | 0x0 | 1 | 65536 | 12845056 | 8 |  |  |
| 113 | conv_45.conv.bn | BatchNorm2d | 1x512x14x14 | 1x512x14x14 |  |  |  |  | 1024 |  |  |  |  |
| 114 | conv_45.conv.prelu | QuantActPreLu | 1x512x14x14 | 1x512x14x14 |  |  |  |  | 512 |  |  | 8 | prelu_then_activation_quant |
| 115 | conv_45.conv_dw.conv | Quant_Conv2d | 1x512x14x14 | 1x512x7x7 | 3x3 | 2x2 | 1x1 | 512 | 4608 | 225792 | 8 |  |  |
| 116 | conv_45.conv_dw.bn | BatchNorm2d | 1x512x7x7 | 1x512x7x7 |  |  |  |  | 1024 |  |  |  |  |
| 117 | conv_45.conv_dw.prelu | QuantActPreLu | 1x512x7x7 | 1x512x7x7 |  |  |  |  | 512 |  |  | 8 | prelu_then_activation_quant |
| 118 | conv_45.project.conv | Quant_Conv2d | 1x512x7x7 | 1x128x7x7 | 1x1 | 1x1 | 0x0 | 1 | 65536 | 3211264 | 8 |  |  |
| 119 | conv_45.project.bn | BatchNorm2d | 1x128x7x7 | 1x128x7x7 |  |  |  |  | 256 |  |  |  |  |
| 120 | conv_5.model.0.0.conv.conv | Quant_Conv2d | 1x128x7x7 | 1x256x7x7 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 1605632 | 8 |  |  |
| 121 | conv_5.model.0.0.conv.bn | BatchNorm2d | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 512 |  |  |  |  |
| 122 | conv_5.model.0.0.conv.prelu | QuantActPreLu | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 123 | conv_5.model.0.0.conv_dw.conv | Quant_Conv2d | 1x256x7x7 | 1x256x7x7 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 112896 | 8 |  |  |
| 124 | conv_5.model.0.0.conv_dw.bn | BatchNorm2d | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 512 |  |  |  |  |
| 125 | conv_5.model.0.0.conv_dw.prelu | QuantActPreLu | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 126 | conv_5.model.0.0.project.conv | Quant_Conv2d | 1x256x7x7 | 1x128x7x7 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 1605632 | 8 |  |  |
| 127 | conv_5.model.0.0.project.bn | BatchNorm2d | 1x128x7x7 | 1x128x7x7 |  |  |  |  | 256 |  |  |  |  |
| 128 | conv_5.model.0.1 | QuantAct | 1x128x7x7 | 1x128x7x7 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 129 | conv_5.model.1.0.conv.conv | Quant_Conv2d | 1x128x7x7 | 1x256x7x7 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 1605632 | 8 |  |  |
| 130 | conv_5.model.1.0.conv.bn | BatchNorm2d | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 512 |  |  |  |  |
| 131 | conv_5.model.1.0.conv.prelu | QuantActPreLu | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 132 | conv_5.model.1.0.conv_dw.conv | Quant_Conv2d | 1x256x7x7 | 1x256x7x7 | 3x3 | 1x1 | 1x1 | 256 | 2304 | 112896 | 8 |  |  |
| 133 | conv_5.model.1.0.conv_dw.bn | BatchNorm2d | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 512 |  |  |  |  |
| 134 | conv_5.model.1.0.conv_dw.prelu | QuantActPreLu | 1x256x7x7 | 1x256x7x7 |  |  |  |  | 256 |  |  | 8 | prelu_then_activation_quant |
| 135 | conv_5.model.1.0.project.conv | Quant_Conv2d | 1x256x7x7 | 1x128x7x7 | 1x1 | 1x1 | 0x0 | 1 | 32768 | 1605632 | 8 |  |  |
| 136 | conv_5.model.1.0.project.bn | BatchNorm2d | 1x128x7x7 | 1x128x7x7 |  |  |  |  | 256 |  |  |  |  |
| 137 | conv_5.model.1.1 | QuantAct | 1x128x7x7 | 1x128x7x7 |  |  |  |  | 0 |  |  | 8 | residual_add_output_quant |
| 138 | conv_6_sep.conv | Quant_Conv2d | 1x128x7x7 | 1x512x7x7 | 1x1 | 1x1 | 0x0 | 1 | 65536 | 3211264 | 8 |  |  |
| 139 | conv_6_sep.bn | BatchNorm2d | 1x512x7x7 | 1x512x7x7 |  |  |  |  | 1024 |  |  |  |  |
| 140 | conv_6_sep.prelu | QuantActPreLu | 1x512x7x7 | 1x512x7x7 |  |  |  |  | 512 |  |  | 8 | prelu_then_activation_quant |
| 141 | output_layer.conv_6_dw.conv | Quant_Conv2d | 1x512x7x7 | 1x512x1x1 | 7x7 | 1x1 | 0x0 | 512 | 25088 | 25088 | 8 |  |  |
| 142 | output_layer.conv_6_dw.bn | BatchNorm2d | 1x512x1x1 | 1x512x1x1 |  |  |  |  | 1024 |  |  |  |  |
| 143 | output_layer.linear | Quant_Linear | 1x512 | 1x128 |  |  |  |  | 65536 | 65536 | 8 |  |  |
| 144 | output_layer.bn | BatchNorm1d | 1x128 | 1x128 |  |  |  |  | 256 |  |  |  |  |
