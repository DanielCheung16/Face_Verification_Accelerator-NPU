# Eyeriss 實作筆記

> **來源論文：** Eyeriss: An Energy-Efficient Reconfigurable Accelerator for Deep Convolutional Neural Networks  
> **重點：** 本文不是單純摘要，而是拆成「可以拿來實作」的架構說明與 RTL 落地指引。

---

## 目錄

1. [論文核心目標](#1-論文核心目標)
2. [他們實際做了什麼](#2-他們實際做了什麼)
3. [CNN Computation Model](#3-cnn-computation-model)
4. [系統架構](#4-系統架構)
5. [Row Stationary Dataflow](#5-row-stationary-dataflow)
6. [RS Dataflow 實作方式](#6-rs-dataflow-實作方式)
7. [N、C、M 維度的處理](#7-ncm-維度的處理)
8. [Processing Pass](#8-processing-pass)
9. [Global Buffer 設計](#9-global-buffer-設計)
10. [NoC 設計](#10-noc-設計)
11. [PE 內部設計](#11-pe-內部設計)
12. [Zero Data Gating](#12-zero-data-gating)
13. [RLC Compression](#13-rlc-compression)
14. [晶片規格](#14-晶片規格)
15. [驗證與量測結果](#15-驗證與量測結果)
16. [Power / Area 分析](#16-power--area-分析)
17. [RTL 落地：如何實作](#17-rtl-落地如何實作)
18. [對照 MobileFaceNet RTL 的升級方向](#18-對照-mobilefacenet-rtl-的升級方向)
19. [驗證方法](#19-驗證方法)
20. [設計精髓總結](#20-設計精髓總結)

---

## 1. 論文核心目標

這篇論文的核心問題是：

> CNN 的計算量很大，但真正耗能的不只是 MAC，而是**資料搬移**，尤其是 DRAM access。

Eyeriss 的目標不是單純把 MAC 數量堆高，而是讓整個系統（accelerator chip + off-chip DRAM）都達到高能效。論文指出 CNN inference 需要大量參數與 feature maps，會造成大量 on-chip / off-chip data movement；而 data movement 的能耗可能比 computation 還大，所以設計重點必須放在**減少資料搬移**。

他們最後做出一顆真正 **fabricated** 的 CNN accelerator chip，不只是 simulation，也不是 FPGA demo。這點很重要，因為論文批評前人的很多 CNN accelerator 只給 simulation 或 FPGA 結果，沒有真正量到 fabricated chip 的 power、throughput、DRAM bandwidth。

---

## 2. 他們實際做了什麼

Eyeriss 是一個 spatial CNN accelerator，硬體包含：

| 元件 | 實際規格 |
|------|----------|
| PE array | 168 個 PE，排列成 12 × 14 |
| Global Buffer | 108 KB SRAM |
| NoC | 支援 multicast 與 point-to-point PE communication |
| PE local storage | 每個 PE 有獨立 scratchpads |
| Compression | RLC（Run-Length Compression） |
| Activation | ReLU module |
| Control | Top-level controller + PE local controller |
| Fabrication | 65 nm CMOS |
| System demo | 整合 Caffe，透過 Jetson TK1 + PCIe + VC707 demo |

**四大核心特色：**

1. **168 PE spatial architecture** — CNN computation spatially map 到 PE array
2. **四層 memory hierarchy** — `DRAM → Global Buffer → inter-PE → PE scratchpad`，設計目標是把 reuse 留在低能耗層級
3. **Row Stationary dataflow** — 讓 filter、ifmap、psum 都盡量 reuse
4. **RLC compression + data gating** — 利用 ReLU 後大量 zero 的特性，減少 DRAM bandwidth 與 PE switching power

---

## 3. CNN Computation Model

論文中的 CNN layer 計算式：

```
O[n][m][x][y] =
  ReLU(
    B[m] +
    Σ (c, r, s): I[n][c][Ux+r][Uy+s] * W[m][c][r][s]
  )
```

| 符號 | 意義 |
|------|------|
| N | batch size |
| M | output channels / filters 數量 |
| C | input channels |
| H, W | input feature map height / width |
| R, S | filter height / width |
| E, F | output feature map height / width |
| U | stride |

**MobileFaceNet RTL 目前的 loop 結構：**

```
for y
  for x
    for output channel
      for input channel
        for ky
          for kx
            psum += input * weight
```

Eyeriss 則不是直接照 nested loop 做，而是把 computation **重新 map** 成可以在 PE array 上 reuse 的型態。

---

## 4. 系統架構

### 4.1 Top-level 架構

Eyeriss 有兩個 clock domain：

| Clock domain | 功能 |
|--------------|------|
| Link clock domain | 跟 off-chip DRAM 溝通 |
| Core clock domain | PE array、GLB、NoC、RLC、ReLU 執行 CNN |

兩個 domain 之間透過 **asynchronous FIFO** 溝通。

**資料流：**

```
Off-chip DRAM
    ↓
RLC Decoder
    ↓
Global Buffer (108 KB)
    ↓
NoC (GIN)
    ↓
PE Array (12 × 14)
    ↓
NoC (GON)
    ↓
Global Buffer
    ↓
ReLU / RLC Encoder
    ↓
Off-chip DRAM
```

系統以 layer-by-layer、tile-by-tile 的方式處理，不是一次把所有資料塞進 PE。

---

### 4.2 控制架構

**Top-level control** 負責：
- DRAM ↔ GLB traffic
- GLB ↔ PE array traffic
- RLC encoder / decoder 控制
- ReLU 控制
- 每層 configuration loading

**PE local control：**
- 每個 PE 裡有自己的 controller
- Eyeriss **不是** systolic array，168 個 PE 不需要 lock-step
- 每個 PE 只要資料到了，就可以開始自己的 processing

---

### 4.3 每一層的啟動流程

```
1. 載入 layer configuration bits（透過 1794-bit scan chain，< 100 μs）
2. 設定 PE array mapping
3. 設定 NoC delivery pattern
4. 從 DRAM 載入 ifmap / filter tiles 到 GLB
5. GLB 透過 NoC 把資料送到 PE array
6. PE array 計算 psum / ofmap
7. ofmap 經 ReLU / RLC compression
8. 寫回 DRAM
```

> **對應你的設計：** `mfn_layer_config_rom.sv` 就是 Eyeriss scan-chain config 的簡化版。你用 ROM 存 layer config；Eyeriss 用 scan chain 存完整的 mapping / NoC control / PE setup。

---

## 5. Row Stationary Dataflow

RS dataflow 是 Eyeriss 最重要的貢獻，它不是單純 weight stationary 或 output stationary，而是**同時**最佳化三種資料：

| 資料 | 要減少的問題 |
|------|------------|
| ifmap | 重複讀 input feature map |
| filter | 重複讀 weight |
| psum | partial sum 反覆寫回大記憶體 |

**RS dataflow 目標：** 讓資料盡量在低能耗層級 reuse

```
PE spad reuse > inter-PE reuse > GLB reuse > DRAM reuse
```

---

## 6. RS Dataflow 實作方式

### Step 1：把 2D Convolution 拆成 1D Convolution Primitive

一個 primitive 做的事：

```
一列 filter weights × 一列 ifmap values → 一列 partial sums
```

例如 filter row size S=3，ifmap row size W=5：

```
filter row:  [w0 w1 w2]
ifmap row:   [x0 x1 x2 x3 x4]

cycle 0: w0*x0 + w1*x1 + w2*x2 → psum0
cycle 1: w0*x1 + w1*x2 + w2*x3 → psum1
cycle 2: w0*x2 + w1*x3 + w2*x4 → psum2
```

這個 primitive 被 map 到**單一個 PE**。每個 PE 保存：
- `filter row spad`
- `ifmap sliding window spad`
- `psum register / psum spad`

PE spad 的容量只跟 filter row size S 有關，不跟整個 ifmap width W 有關，這是很大的 energy saving。

---

### Step 2：把多個 1D Primitive 組成 2D Convolution PE Set

3×3 convolution 的 PE set：

```
PE row 0: filter row 0 × ifmap row 0
PE row 1: filter row 1 × ifmap row 1
PE row 2: filter row 2 × ifmap row 2
```

PE set 的 reuse pattern（對應論文 Fig. 4）：

| 方向 | 資料行為 |
|------|---------|
| horizontal | filter row reuse |
| diagonal | ifmap row reuse |
| vertical | psum accumulation |

---

### Step 3：PE Set 尺寸決定方式

```
PE set height = R（filter height）
PE set width  = E（output feature map rows）
```

AlexNet 各層原始 PE set size：

| Layer | 原始 PE set size |
|-------|----------------|
| CONV1 | 11 × 55 |
| CONV2 | 5 × 27 |
| CONV3–CONV5 | 3 × 13 |

但 Eyeriss 實體 PE array 只有 **12 × 14 = 168 PEs**，所以 PE set 太大時必須切割。

---

### Step 4：PE Set 放不下時的處理方式

**Case 1：PE set 超過 168 PEs → Strip Mining**

AlexNet CONV1 原始 `11 × 55`，切成 `11 × 7`，一次只算一部分 output rows。

**Case 2：PE set 寬度超過 14 → 分段 Map**

CONV2 `5 × 27`（總數 135 < 168，但寬度 27 > 14）：

```
5 × 14  →  map 到 PE array 前半
5 × 13  →  map 到 PE array 後半
```

> **對你的影響：** MobileFaceNet 中 feature map 很寬或 channel 很大時，你現在用時間 loop 解決；Eyeriss 是用 spatial mapping + strip mining 解決。

---

## 7. N、C、M 維度的處理

Eyeriss 用 mapping parameters 控制 batch、channel、filter 維度：

| 參數 | 意義 |
|------|------|
| `m` | GLB 中存多少 ofmap channels |
| `n` | 每個 processing pass 處理多少 ifmaps |
| `e` | 每個 PE set 處理多少 ofmap rows |
| `p` | 每個 PE set 處理多少 filters |
| `q` | 每個 PE 處理多少 channels |
| `r` | PE array 中有多少 PE sets 處理不同 channels |
| `t` | PE array 中有多少 PE sets 處理不同 filters |

每個 PE 同時 interleave `p × q` 個 primitive，所需 spad 容量：

```
filter spad:  p × q × S
ifmap spad:   q × S
psum spad:    p
```

Eyeriss 的 PE spad 規格：

| Spad | 大小 |
|------|------|
| ifmap spad | 12 × 16-bit |
| filter spad | 224 × 16-bit |
| psum spad | 24 × 16-bit |

因此在 AlexNet 中，`p` 最多可到 24，`q` 最多可到 4。

---

## 8. Processing Pass

Eyeriss 不是一次做完整 layer，而是分成很多 **processing passes**：

```
for each layer:
  configure mapping
  for each processing pass:
    load needed ifmap/filter tile from GLB
    run PE array
    accumulate psum
  compress/write final ofmap
```

GLB 的作用是在 passes 之間保存 ifmaps（reuse）和 psums（accumulation），使 psum 不需要每次都寫回 DRAM。一個 CNN layer 通常需要**數百到數千個** processing passes。

**對應 RTL 的 FSM 狀態：**

```
STATE_LOAD_CONFIG
STATE_LOAD_TILE
STATE_RUN_PASS
STATE_ACCUM_PSUM
STATE_WRITEBACK
STATE_NEXT_PASS
STATE_NEXT_LAYER
```

---

## 9. Global Buffer 設計

Eyeriss 的 GLB 是 **108 KB**，結構如下：

| 容量 | 用途 |
|------|------|
| 100 KB | ifmaps + psums |
| 8 KB | filters |

100 KB 被切成 **25 個 SRAM banks**，每個 bank 為 `512 × 64-bit = 4 KB`。

每個 bank 可以動態設定為 ifmap bank 或 psum bank，根據每層需要的比例調整。這是 **reconfigurable allocation**，避免固定切割造成浪費。

**RTL 實作（簡化版）：**

```systemverilog
logic [63:0] glb_bank [0:24][0:511];
logic bank_is_psum [0:24];

// 每層 config 設定 bank 分配
for (int i = 0; i < 25; i++) begin
    bank_is_psum[i] = (i >= num_ifmap_banks);
end
```

---

## 10. NoC 設計

Eyeriss 的 NoC 是為 RS dataflow **客製化**的，有三個 network：

| Network | 功能 |
|---------|------|
| GIN（Global Input Network） | GLB → PE array |
| GON（Global Output Network） | PE array → GLB |
| Local Network | PE ↔ PE，主要傳 psum |

---

### 10.1 GIN：Global Input Network

GIN 支援 **single-cycle multicast**，把 filter / ifmap / psum 從 GLB 傳到多個 PE。

**需要 multicast 的原因：** RS dataflow 中很多 PE 同時需要同一個資料（filter row 水平 reuse、ifmap value 對角線 reuse）。若每個 PE 各自從 GLB 讀一次，GLB bandwidth 和 energy 都爆掉。

**GIN 結構（兩層 bus hierarchy）：**

```
Y-bus
  └── X-bus per row
        └── PEs in that row
```

每筆資料帶一個 tag `(row_tag, col_tag)`。當 tag match 時，資料才送進 PE；不 match 的 bus / PE 會 clock gated 省電。

---

### 10.2 GON：Global Output Network

架構與 GIN 類似，方向相反（PE array → GLB），用於把一個 processing pass 產生的 psum / ofmap 送回 GLB。

---

### 10.3 Local Network

相鄰兩列、同一欄的 PE 之間有一條 **64-bit dedicated bus**：

```
PE(row+1, col) psum → PE(row, col)
```

這就是 RS dataflow 的 vertical psum accumulation，psum 不需要回 GLB 再讀回來，直接在 PE array 裡 accumulate。

---

## 11. PE 內部設計

每個 PE 的組成：

| 元件 | 功能 |
|------|------|
| I/O FIFOs | 平衡 NoC 和 PE compute 的速度 |
| ifmap spad | 存 sliding window ifmap |
| filter spad | 存 filter weights |
| psum spad | 存 partial sums |
| multiplier | 16-bit two-stage pipelined multiplier |
| adder | psum accumulation |
| PE control | 控制 p、q interleaving 與 spad stepping |
| zero buffer | 記錄 ifmap spad 中哪些值是 zero |
| data gating | 遇到 zero ifmap 時關閉 filter spad read 和 MAC switching |

PE datapath 分三個 pipeline stage：

```
Stage 1: spad access
Stage 2: multiplier
Stage 3: adder / accumulation
```

**Arithmetic：** 16-bit fixed-point。乘法結果為 32-bit，但只取其中 16 bits，選哪 16 bits 是 configurable，依照每層 dynamic range offline 決定。

> **對照你的 RTL：**
> - 你現在是 `int16 × int16 → int40 → shift → int16`
> - Eyeriss 是 `16-bit × 16-bit → truncated/selected 16-bit → psum`
> - Eyeriss 更 aggressively 做 bit-width control，因為是 65 nm ASIC 能效最佳化

---

## 12. Zero Data Gating

Eyeriss 利用 ReLU 造成的 zero feature maps，在 PE 裡加入 **12-bit Zero Buffer** 記錄 ifmap spad 中哪些位置是 zero。

**運作邏輯：**

```python
if ifmap == 0:
    gate filter_spad_read
    gate multiplier
    skip switching
else:
    normal MAC
```

**論文量測結果：** 跟沒有 data gating 相比，可節省 **45% PE power**。

**RTL 實作（ASIC friendly）：**

```systemverilog
logic mac_en;
assign mac_en = (act_in[i] != 16'sd0);

always_comb begin
    if (mac_en) begin
        mult_a = act_in[i];
        mult_b = wgt_in[i];
    end else begin
        mult_a = '0;
        mult_b = '0;
    end
end
```

讓 multiplier input 不 toggle，ASIC synthesis tool 可以進一步做 clock gating。

---

## 13. RLC Compression

Eyeriss 用 **Run-Length Compression（RLC）** 壓縮 DRAM 中的 feature maps（ReLU 後有大量 zero）。

**RLC 格式：**

| 欄位 | 位元數 | 意義 |
|------|--------|------|
| Run | 5 bits | 前面連續 0 的數量（最大 31） |
| Level | 16 bits | 下一個非零值 |
| Term bit | 1 bit | 是否為最後一個 code word |

每三組 run-level pair 打包成一個 64-bit word。

**範例：**

```
input:  0, 0, 12, 0, 0, 0, 0, 53, 0, 0, 22

output:
  (run=2, level=12)
  (run=4, level=53)
  (run=2, level=22)
```

**壓縮位置：** DRAM 存壓縮後的 fmaps；GLB 存解壓縮後的資料；PE 計算完後，ofmap 經 ReLU 再壓縮回 DRAM。

```
DRAM (compressed)
    ↓ RLC Decoder
GLB (decompressed)
    ↓ PE array computes
GLB output
    ↓ ReLU
    ↓ RLC Encoder
DRAM (compressed)
```

除了第一層 input 之外，所有 feature maps 都以壓縮形式存在 DRAM。

**AlexNet DRAM access saving：**

| Layer | fmap DRAM access 節省 |
|-------|----------------------|
| CONV1 | ~30% |
| CONV5 | ~75% |

---

## 14. 晶片規格

| 項目 | 數值 |
|------|------|
| Technology | TSMC 65 nm LP 1P9M |
| Chip size | 4.0 mm × 4.0 mm |
| Core area | 3.5 mm × 3.5 mm |
| Number of PEs | 168 |
| GLB | 108 KB SRAM |
| PE filter spad | 448 bytes SRAM |
| PE ifmap spad | 24 bytes registers |
| PE psum spad | 48 bytes registers |
| Core voltage | 0.82–1.17 V |
| I/O voltage | 1.8 V |
| Core clock | 100–250 MHz |
| Link clock | up to 90 MHz |
| Arithmetic precision | 16-bit fixed-point |
| Peak throughput | 16.8–42.0 GMAC/s |

在 1 V、200 MHz core clock 下，peak throughput 為 **33.6 GMAC/s**。

---

## 15. 驗證與量測結果

### 15.1 System Demo

```
Customized Caffe
    ↓
NVIDIA Jetson TK1
    ↓ PCIe x1
Xilinx VC707（作 PCIe controller，不做 CNN processing）
    ↓
Eyeriss chip
```

Demo：ImageNet 1000-class classification。

---

### 15.2 AlexNet 結果（1 V，batch size N=4）

| 指標 | 結果 |
|------|------|
| Average frame rate | 34.7 frames/s |
| Processing throughput | 23.1 GMAC/s |
| Measured chip power | 278 mW |
| Energy efficiency | 83.1 GMAC/s/W |
| DRAM access per batch | 15.4 MB |
| DRAM access per MAC | 0.0029 access/MAC |

Throughput 低於 peak throughput 的三個原因：
1. 約 88% PEs active
2. 每個 processing pass 開始時，GLB → PE array 需要 ramp-up time
3. 從 DRAM 載入 ifmap 或 dump ofmap 時沒有同時 processing（可透過更細緻的 DRAM traffic control 改善）

---

### 15.3 VGG-16 結果（1 V，batch size N=3）

| 指標 | 結果 |
|------|------|
| Average frame rate | 0.7 frames/s |
| Measured power | 236 mW |
| Total MACs | 46.04G |
| DRAM access per batch | 321.1 MB |
| DRAM access per MAC | 0.0035 access/MAC |

VGG-16 frame rate 比 AlexNet 低，因為每張圖的 computation 約是 AlexNet 的 23 倍。

---

## 16. Power / Area 分析

### 16.1 Area Breakdown

Eyeriss 的 on-chip storage（GLB + 所有 PE spads）佔總面積約 **三分之二**；所有 multipliers 和 adders 只佔 **7.4%**。

**結論：**

> 在 CNN accelerator 裡，**不是 MAC 最貴**，而是資料儲存與資料搬移結構很貴。

---

### 16.2 Power Breakdown

比較 AlexNet CONV1 和 CONV5：

- ALU power **少於 10%**
- spads、GLB、NoC 等 data movement components 最多可佔 **45%**
- CONV5 因為 ifmap zeros 更多，spad / MAC power 明顯下降

**結論：**

> CNN accelerator 的能效瓶頸主要是 **data movement**，不只是 computation。

---

## 17. RTL 落地：如何實作

### 17.1 最小可行版本

不需要一開始就做完整 168 PE + NoC + RLC，可以先做：

```
eyeriss_top.sv
eyeriss_controller.sv
layer_config_rom.sv
global_buffer.sv
pe_array.sv
pe.sv
gin_simple.sv
gon_simple.sv
local_psum_network.sv
rlc_encoder.sv        # optional
rlc_decoder.sv        # optional
```

---

### 17.2 PE 模組介面

```systemverilog
module pe #(
    parameter DATA_W           = 16,
    parameter PSUM_W           = 32,
    parameter IFMAP_SPAD_DEPTH = 12,
    parameter FILTER_SPAD_DEPTH= 224,
    parameter PSUM_SPAD_DEPTH  = 24
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       ifmap_valid,
    input  logic signed [DATA_W-1:0]   ifmap_in,
    input  logic                       filter_valid,
    input  logic signed [DATA_W-1:0]   filter_in,
    input  logic                       psum_valid,
    input  logic signed [PSUM_W-1:0]   psum_in,
    output logic                       psum_out_valid,
    output logic signed [PSUM_W-1:0]   psum_out
);
```

PE 內部組成：`ifmap_spad`、`filter_spad`、`psum_spad`、`zero_buffer`、multiplier pipeline、adder pipeline、local controller。

**PE 運作流程：**

```
1. load filter row into filter_spad
2. load ifmap sliding window into ifmap_spad
3. for each output position:
      if ifmap != 0:
          product = ifmap * filter
          psum += product
      else:
          skip multiplier switching
4. send psum to upper PE or GON
```

---

### 17.3 1D Convolution Primitive 狀態機

```
IDLE
LOAD_FILTER_ROW
LOAD_IFMAP_WINDOW
MAC_LOOP
SHIFT_WINDOW
OUTPUT_PSUM
```

**核心 pseudo-code：**

```python
for out_x in range(E):
    psum = psum_in
    for s in range(S):
        psum += ifmap_window[s] * filter_row[s]
    output psum
    shift ifmap window by stride
```

支援 p / q interleaving 的版本：

```python
for q_channel in range(q):
    for p_filter in range(p):
        psum[p_filter] += ifmap[q_channel][s] * filter[p_filter][q_channel][s]
```

---

### 17.4 PE Set 實作（以 3×3 Conv 為例）

```
PE row 0: filter row 0 × ifmap row 0
PE row 1: filter row 1 × ifmap row 1
PE row 2: filter row 2 × ifmap row 2
```

Vertical psum accumulation：

```
PE row 2 output psum
    ↓ add
PE row 1
    ↓ add
PE row 0
    ↓
final psum / ofmap row
```

RTL 實作：

```systemverilog
logic signed [PSUM_W-1:0] local_psum_bus [ROWS][COLS];
// 資料方向：local_psum_bus[row+1][col] → PE[row][col]
```

---

### 17.5 GIN 簡化實作（支援 Multicast）

```systemverilog
typedef struct packed {
    logic [3:0]  row_tag;
    logic [4:0]  col_tag;
    logic [15:0] data;
} gin_packet_t;

// 每個 PE：
if (packet.row_tag == my_row_id && packet.col_tag == my_col_id)
    accept_data <= 1'b1;
```

**Multicast trick：** 讓多個 PE 設相同的 col_id，同一筆 packet 會同時送到所有符合 tag 的 PE，不需要 168-bit destination vector。

---

### 17.6 Processing Pass Controller FSM

```
RESET
LOAD_LAYER_CONFIG
CONFIGURE_PE_IDS
CONFIGURE_GLB_BANKS
LOAD_IFMAP_TILE_FROM_DRAM
LOAD_FILTER_TILE_FROM_DRAM
ISSUE_GIN_PACKETS
RUN_PE_ARRAY
COLLECT_GON_PSUMS
ACCUMULATE_GLB_PSUMS
CHECK_PASS_DONE
WRITEBACK_OFMAP
NEXT_LAYER
DONE
```

**Processing pass 的 nested loop：**

```python
for layer in layers:
    config_layer(layer)
    for n_tile in range(N):
        for m_tile in range(0, M, p*t):
            for c_tile in range(0, C, q*r):
                for e_tile in range(0, E, e):
                    run_processing_pass()
```

---

### 17.7 RLC Encoder FSM

```
ZERO_COUNT
EMIT_RUN_LEVEL
PACK_64B_WORD
WRITE_COMPRESSED
```

**核心邏輯：**

```python
run = 0
for value in stream:
    if value == 0 and run < 31:
        run += 1
    else:
        emit(run, value)
        run = 0
```

---

## 18. 對照 MobileFaceNet RTL 的升級方向

**目前 MobileFaceNet RTL 架構：**

```
mfn_controller
mfn_addr_gen
mfn_sliding_window
mfn_mac_array
mfn_activation
weight/bias/prelu/config ROM
SRAM ping-pong
```

這是中央式 CNN engine，Eyeriss 提供幾個升級方向：

---

### 18.1 把 single MAC array 改成 PE array

現在：

```
one MAC array computes one output at a time
```

目標：

```
3 rows × K columns PE array

row 0 handles ky=0
row 1 handles ky=1
row 2 handles ky=2

vertical accumulation: row2 psum → row1 → row0 → output
```

這就是 Eyeriss PE set 的核心概念。

---

### 18.2 把 sliding window buffer 分散到 PE spad

| 階段 | 架構 |
|------|------|
| 第一階段（現況） | global `sliding_window` feeds all MAC lanes |
| 第二階段 | each PE has local ifmap row buffer |
| 第三階段 | PE-to-PE ifmap / psum reuse |

---

### 18.3 加 Zero Gating

在 `mfn_mac_array.sv` 中：

```systemverilog
if (act_in[i] == 16'sd0) begin
    prod[i] = '0;
    // ASIC: clock/data gating tool 可關掉 multiplier input toggle
end else begin
    prod[i] = signed'(act_in[i]) * signed'(wgt_in[i]);
end
```

---

### 18.4 加 RLC 壓縮輸出

```
ofmap stream
    ↓
RLC encoder
    ↓
compressed SRAM / DRAM
```

---

### 18.5 擴充 Layer Config 的 config 化程度

可以把更多東西加進 `mfn_layer_config_rom.sv`：

```
is_dw
is_pw
stride
padding
input/output shape
channel count
ping-pong base
psum mode
shortcut mode
zero_gating enable
```

---

## 19. 驗證方法

### 19.1 Functional Verification

```
Golden model（Python / C model）→ layer*_out_fixed.txt
RTL simulation → rtl_out.hex
比對：exact match、±1 match、max diff、mean diff、mismatch locations
```

你的 `verify_rtl.py` 已是這個 flow。

---

### 19.2 Data Movement Verification（仿 Eyeriss 風格）

加入 counters，最後 print：

```
dram_read_count
dram_write_count
sram_read_count
sram_write_count
weight_read_count
ifmap_read_count
psum_read_count

Total MACs
Total SRAM accesses
Total DRAM accesses
Accesses / MAC
```

---

### 19.3 PE Utilization Verification

```systemverilog
pe_active_cycles[i]
total_cycles

// PE utilization = sum(pe_active_cycles) / (num_pe * total_cycles)
```

---

### 19.4 Power Proxy Verification（無 ASIC power tool 的替代方案）

```
Total MAC opportunities
Skipped zero MACs
Zero skip rate
Estimated multiplier activity reduction

Number of multiplier toggles
Number of SRAM reads / writes
```

這對應 Eyeriss 的 data gating analysis。

---

## 20. 設計精髓總結

### 原則 1：資料搬移比 MAC 更重要

Eyeriss 的 area / power breakdown 都證明 multiplier 和 adder 不是主角。真正耗能的是 spads、GLB、NoC、DRAM traffic、clock network。

**設計時先問：**

> - 這個 dataflow 讓資料在哪裡 reuse？
> - psum 有沒有盡快 reduce？
> - ifmap / filter 有沒有少讀？

而不是只問：我有多少 MACs？

---

### 原則 2：同時最佳化 ifmap、filter、psum

很多 accelerator 只做 weight stationary 或 output stationary。Eyeriss 的 RS dataflow 是想同時照顧三者，這就是 row stationary 的核心。

---

### 原則 3：mapping 要可重組

CNN layer shape 變化很大（CONV1 large filter, VGG many 3×3），所以 Eyeriss 用 scan-chain configuration、mapping parameters、NoC row/col IDs、GLB bank allocation 讓同一個硬體支援不同 layer。

---

### 原則 4：壓縮和 gating 是系統級優化

- **RLC** 改變 DRAM traffic，不影響 functional correctness
- **Data gating** 利用 zero input 避免不必要 switching，不改變答案

兩者都不影響功能，但大幅影響 energy。

---

## 一句話總結

> Eyeriss 實作了一顆 65 nm、168 PE、108 KB GLB 的 CNN accelerator，透過 **Row Stationary dataflow** 把 convolution 拆成 row-based primitives 並 map 到 PE array，使 filter、ifmap、psum 都能在 PE spad、inter-PE link、GLB 中最大化 reuse，再搭配 **RLC compression** 和 **zero data gating** 減少 DRAM traffic 與 PE power，最後用 fabricated chip 在 AlexNet 和 VGG-16 上量測 throughput、power、DRAM accesses，證明整體系統能效比只看 MAC throughput 更重要。
