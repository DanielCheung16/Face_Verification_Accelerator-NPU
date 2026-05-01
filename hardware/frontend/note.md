# MobileFaceNet Frontend RTL 開發筆記

## 目前狀態摘要

| 範圍 | 內容 | 狀態 |
|------|------|------|
| Layer 0 | Conv1 (3→64, stride 2) | ✅ **100.00% Exact Match** |
| Layer 1 | DW1 (64ch, stride 1) | ✅ **100.00% Exact Match** |
| Layer 2–4 | Bottleneck Block 0 (stride 2, 64ch) | ✅ **100.00% Exact Match** |
| Layer 5–7 | Bottleneck Block 1 (stride 1, 64ch, Residual) | ✅ **100.00% Exact Match** |
| Layer 8–16 | Bottleneck Block 2–4 (stride 1, 64ch, Residual) | ✅ **100.00% Exact Match** |
| Layer 17–19 | Bottleneck Block 5 (stride 2, 64→256→128ch) | ✅ **100.00% Exact Match** |
| Layer 20–37 | Bottleneck Block 6–11 (stride 1, 128ch, Residual) | ✅ **100.00% Exact Match** |
| Layer 38–40 | Bottleneck Block 12 (stride 2, 128→512→128ch) | ✅ **100.00% Exact Match** |
| Layer 41–46 | Bottleneck Block 13–14 (stride 1, 128ch, Residual) | ✅ **100.00% Exact Match** |
| Layer 47 | Conv2 (128→512, 1×1) | ✅ **100.00% Exact Match** |
| Layer 48 | linear7 (Global DW 7×6, 512ch → 1×1) | ✅ **100.00% Exact Match** |
| Layer 49 | linear1 (1×1 PW, 512→128) | ✅ **100.00% Exact Match** |

> **全 50 層總執行時間：43,158,478 cycles**（含 addr_gen + activation 2-stage pipeline 優化，+3.4% vs 41,732,515）

---

## 1. 專案目標與範圍

本文件記錄 MobileFaceNet 硬體加速器 Frontend RTL 的架構、資料格式、驗證流程、debug 歷程與 synthesis 優化紀錄。

Frontend RTL 開發重點：

1. 支援 MobileFaceNet 前幾層 convolution 的硬體執行
2. 使用 fixed-point 格式與 C-model / PyTorch golden output 做 bit-level 驗證
3. 建立 multi-layer ping-pong SRAM 資料流
4. 逐步擴充支援：
   - 3×3 Standard Conv
   - 3×3 Depthwise Conv
   - 1×1 Pointwise Conv
   - Bottleneck residual shortcut

---

## 2. 架構總覽

MobileFaceNet Frontend RTL 採模組化設計，分為資料路徑、控制路徑與記憶體子系統，目標是提高可重用性、可除錯性與後續擴充性。

### 2.1 Data Path

#### `mfn_sliding_window.sv`
- 9-entry 隨機存取像素緩衝區
- Controller 依序載入 3×3 區域的 9 個 pixels
- MAC Array 一次讀出全部 9 個 pixels 進行點積

#### `mfn_mac_array.sv`
- 全並行 9 個 16-bit signed multiplier
- **輸入：** 9 個 `int16` activation / pixel + 9 個 `int16` weight
- **輸出：** 40-bit signed dot product
- 已修正 signed multiplication sign extension 問題（使用 `signed'(act_in[i])` 類型轉換）
- 後續 synthesis 優化中已加入 pipeline register，以降低 critical path

#### `mfn_activation.sv`

Activation 順序與 fixed C-model 對齊：

1. Q20 accumulator 先 `>>> 10` 量化為 Q10
2. Clamp 到 `int16` 範圍
3. 執行 PReLU（使用 16×16 → 32-bit 乘法）

此順序修正後，RTL 與 fixed golden 的一致性大幅提升。

---

### 2.2 Control Path

#### `mfn_addr_gen.sv`
- 負責 SRAM read/write address generation
- 支援 signed padding 座標
- Input feature map 使用 HWC layout：

  ```
  addr = (y * Width + x) * InCh + c
  ```

- Write address 使用 ping-pong base offset，避免輸入輸出互相覆蓋
- 早期版本使用固定 `0x10000` 作為 output base；Layer 2 debug 後改為 `0x2A000`，避免 Layer 1 output 被覆蓋

#### `mfn_controller.sv`
- 主控制 FSM，採 Two-Process Methodology
- 支援多層 nested loop：`Layer → Spatial(Y, X) → c_in → c_out`
- 已支援 Standard Conv、Depthwise Conv、Pointwise Conv
- 已修正多個 pipeline alignment 問題（SRAM 1-cycle read latency、activation valid timing）

---

### 2.3 Memory Subsystem

| 模組 | 說明 |
|------|------|
| `mfn_weight_rom.sv` | 組合邏輯讀取，每次提供 9 個 `int16` weights（對應 3×3 kernel） |
| `mfn_bias_rom.sv` | 組合邏輯讀取，提供 32-bit Q20 bias |
| `mfn_prelu_rom.sv` | 組合邏輯讀取，提供 per-channel `int16` Q10 PReLU alpha |
| `mfn_layer_config_rom.sv` | 64-bit config format，儲存每層 convolution 的 configuration |

`mfn_layer_config_rom.sv` 支援欄位：layer dimensions、stride / padding、input / output channel、`is_dw`、`is_pw`、`ping_pong`、`wgt_base`

---

## 3. 資料格式與記憶體佈局

### 3.1 Fixed-Point Format

| 資料 | 格式 | 位寬 | 說明 |
|------|------|------|------|
| 輸入像素 | Q10 | `int16` | `value = float × 1024` |
| 權重 | Q10 | `int16` | 來源：`golden_weights_fixed/conv*_weight.txt` |
| Bias | Q20 | `int32` | 來源：`golden_weights_fixed/conv*_bias.txt` |
| PReLU Alpha | Q10 | `int16` | 來源：`golden_weights_fixed/conv*_prelu.txt` |
| 內部累加器 | Q20 | `int40` | `pixel(Q10) × weight(Q10) = Q20` |
| 輸出像素 | Q10 | `int16` | accumulator `>>> 10` 後 clamp |

### 3.2 SRAM Layout

**Input Feature Map**
- Layout：HWC
- Base address：`0x00000`
- Address formula：`addr = (y * W + x) * C + c`

**Output Feature Map**
- Layout：HWC
- 使用 ping-pong SRAM 區域
- 早期 Layer 0 output base：`0x10000`
- Layer 2 修正後 ping-pong offset：`0x2A000`

**Golden 比對格式**
- RTL output 為 HWC，Golden output 為 CHW
- 比對前需要：`RTL HWC → transpose → CHW → compare with Golden`

### 3.3 Layer 0 / Conv1 維度

| 項目 | 數值 |
|------|------|
| Input shape | `(C=3, H=112, W=96)` |
| PyTorch input shape | `(1, 3, 112, 96)` |
| Output shape | `(C=64, H=56, W=48)` |
| Stride | 2 |
| Padding | 1 |
| Weight shape | `(64, 3, 3, 3)` |
| Weight count | 1728 `int16` |

---

## 4. 權重與 Golden 檔案來源

| 目錄 / 檔案 | 格式 | 用途 |
|-------------|------|------|
| `software/golden_weights/` | float | PyTorch BN 融合後的原始權重，用於 float C-model |
| `software/golden_weights_fixed/` | `int16` / `int32` decimal | 預量化定點權重，供 `gen_hex.py` 與 RTL 使用 |
| `software/golden/layer0_out_c.txt` | float | 舊版 float C-model output（已不作為主要驗證依據） |
| `software/golden/layer0_out_fixed.txt` | `int16` decimal | 定點 C-model output，`verify_rtl.py` 比對用 |
| `software/golden/layer*_out_fixed.txt` | `int16` decimal | 各 layer fixed golden output |

---

## 5. 驗證流程

### Step 1：產生 HEX 檔

```bash
cd hardware/frontend/sim
python3 gen_hex.py
```

產生：`input.hex`、`weights.hex`、`bias.hex`、`prelu.hex`、`config.hex`

### Step 2：執行 RTL 模擬

```bash
make top
```

透過 Xcelium / xrun 執行 SystemVerilog testbench。

### Step 3：數值比對

```bash
cd ../../..
python3 software/verify_rtl.py 0    # 驗證 Layer 0
python3 software/verify_rtl.py 1    # 驗證 Layer 1
python3 software/verify_rtl.py 2    # 驗證 Layer 2
```

`verify_rtl.py` 依據 layer 自動設定：SRAM read offset、output shape、HWC to CHW transpose、對應 golden file。

---

## 6. Debug 歷程與修正紀錄

### Phase A：Layer 0 / Conv1 Debug

#### A.1 起始狀態

最初 `verify_rtl.py` 的結果：

```
Match rate: 0.51%
Golden[0] = -170
RTL[0] = 509
```

觀察到：
- RTL output 充滿飽和值：`32767 / -32768`
- Golden 與 RTL 數值完全不相關
- 第一筆 RTL output `509` 實際上是 input image 的第一筆資料

---

#### A.2 Root Cause Analysis — 5 個獨立 Bug

---

**Bug A1：`gen_hex.py` 的 CHW → HWC 轉換錯誤**

`export_golden.py` 產生的 `layer0_in.txt` 格式為 CHW = `(C=3, H=112, W=96)`，但舊版 `gen_hex.py` 直接執行 `reshape((96, 112, 3))`，維度解讀錯誤。

修正：
```python
reshape((3, 112, 96))
transpose(1, 2, 0)   # CHW → HWC → (H=112, W=96, C=3)
```

---

**Bug A2：`config.hex` 的 H/W 維度寫反**

舊 config 設定 `h=96, w=112`，但 PyTorch input shape 為 `(1, 3, 112, 96)`，正確值應為 `h=112, w=96`。

影響：x/y loop range 錯誤、address calculation 錯誤、output spatial order 錯誤。

修正：更新 `gen_hex.py` 中 config generation 的 height / width 欄位。

---

**Bug A3：`verify_rtl.py` 讀取 SRAM offset 錯誤**

Testbench 使用 `$writememh("rtl_out.hex", sram_mem)` dump 整個 256K SRAM。Layer 0 RTL output 寫在 `sram_mem[0x10000]`，但舊版 `verify_rtl.py` 從 index 0 開始讀，因此讀到的是 input image 資料。

修正：`verify_rtl.py` 從 offset `65536`（`0x10000`）開始讀取，並在 compare 前做 HWC → CHW transpose。

---

**Bug A4：`sram_wr_addr` 與 `valid_out` 時序不對齊**

`mfn_activation.sv` 有 1-cycle pipeline delay，但 `wr_ptr_reg` 在 `inc_write` 同一拍遞增，導致寫入地址比資料早一拍，第一個 output pixel 沒有正確寫到 index 0。

修正：在 `mfn_frontend_top.sv` 中加入一級暫存器，延遲 `sram_wr_addr`，使其與 activation output data 對齊。

---

**Bug A5：Testbench `AWIDTH` 參數錯誤**

`mfn_frontend_top_tb.sv` 中 `AWIDTH = 32`，但 MAC accumulator 需要 40-bit 才能安全存放 Q20 累加結果。

修正：`AWIDTH = 40`

---

#### A.3 Layer 0 驗證歷史

| 版本 | Golden 類型 | 結果 | 說明 |
|------|------------|------|------|
| v1 | Float Golden | 75.75% | 假性 mismatch，float 與 fixed 不一致 |
| v2 | Fixed Golden | 97.33% | PReLU 順序不同 |
| v3 | Fixed Golden + PReLU 修正 | 98.50% | 尚未修正 window stale data |
| v4 | 修正 pipeline bubble | **100.00%** | Exact Match |

---

### Phase B：Layer 0 + Layer 1 / DW-Conv Debug

#### B.1 最新進度

Layer 0 和 Layer 1 Depthwise Conv 已達到 **100.00% Exact Match**。

Layer 0 + Layer 1 完整執行時間：**3,370,758 cycles**

---

#### B.2 SRAM Overwrite：Layer 0 跑兩層後變 37% 的原因

**現象：** 跑完兩層後再驗證 Layer 0，match rate 只剩下約 37%。

**原因：** 這是 ping-pong SRAM 機制下的**預期結果**。

- Layer 0 output 寫入 `0x10000`
- Layer 1 從 `0x10000` 讀取後，寫回 `0x00000`
- Layer 1 output size 為 172,032 pixels，超過 65,536
- 因此 Layer 1 寫入 `0x00000 ~ 0x29FFF` 時，覆蓋掉部分 Layer 0 output 所在區域

**結論：** 這是 ping-pong 機制正常運作的預期行為，不代表 Layer 0 計算錯誤。

---

#### B.3 Window Buffer Stale Data / Pipeline Bubble Bug

**現象：** Layer 1 第一個 output pixel RTL = 323，Golden = 208；Layer 0 單跑只有 98.5% match。

**原因：** 在 `STATE_FETCH_PIXELS` 讀取 3×3 window 時，controller 在送出第 9 筆 pixel address（`k=8`）的同一個 cycle 就切換到 `STATE_CALC_PSUM`。由於 SRAM read 有 1-cycle latency，MAC array 開始計算時 `window_reg[8]` 尚未取得最新資料，使用前一次殘留的 stale data。即每一次 3×3 convolution 的第 9 個 weight 都乘上錯誤 input。

**修正：** 在 `mfn_controller.sv` 中讓 `STATE_FETCH_PIXELS` 多等待 1 cycle（`k_reg < 4'd9`），確保第 9 筆資料進入 `window_reg[8]` 後才切換到 `STATE_CALC_PSUM`。

**結果：**
- Layer 0：98.5% → **100.00%**
- Layer 1 DW-Conv：**100.00%**

---

#### B.4 Phase B 修改檔案

| 檔案 | 修改內容 |
|------|----------|
| `mfn_controller.sv` | 修正 `STATE_FETCH_PIXELS` pipeline timing，避免第 9 筆 window data stale |
| `mfn_frontend_top_tb.sv` | 支援 Layer 0 跑完後自動接 Layer 1；加入 SRAM `0x10000` read/write monitor |
| `gen_hex.py` | 支援兩層權重產生；串接 Layer 0/1 weight/bias/PReLU；實作 64-bit config packing |
| `verify_rtl.py` | 支援多層獨立驗證；`python3 verify_rtl.py 0/1` 指定 layer；自動選擇 SRAM offset |

---

### Phase C：Layer 2 / 1×1 Pointwise Conv Debug

#### C.1 目標

Layer 2 為 1×1 Pointwise Convolution，用於 MobileFaceNet bottleneck block 中的 channel expansion / projection。

特性：
- kernel size = 1×1
- input channel 數量大（如 64 → 128）
- 不需要 3×3 sliding window
- 可優化為一次使用 9 個 MAC lane 處理 9 個 input channels

---

#### C.2 已修正問題

---

**Bug C1：`psum_mem` 深度不足**

`mfn_controller.sv` 中原本 `psum_mem` 深度為 `[0:63]`，但 Layer 2 output channel 為 128。當 channel index 超過 63 時，hardware 讀寫不存在的暫存器位置，造成 `x` unknown value。

修正：`psum_mem` 深度擴充至 128。

---

**Bug C2：Ping-Pong SRAM 位址碰撞覆寫**

`mfn_addr_gen.sv` 中 ping-pong offset 寫死為 `0x10000 = 65,536`，但 Layer 1 output feature map 大小為 172,032 entries。Layer 2 寫入時直接覆寫還需讀取的 Layer 1 output。

修正：ping-pong 距離調大為 `0x2A000 = 172,032`。

---

**Bug C3：Address multiplication overflow**

`pixel_offset` 變數原本只有 16-bit，在計算 `(y * W + x) * C`（`C=64` 或更大）時乘法結果超出 16-bit，導致 overflow 或歸零。

修正：`pixel_offset` 寬度改為 `M_ADDR_WIDTH`（目前 19-bit）。

---

**Bug C4：C-model Golden 順序不一致**

舊版 C-model 的 Quantization / PReLU 順序與 RTL 不一致，造成誤判為 RTL 錯誤。

修正：新增 `gen_pw_golden.py` 作為 Layer 2 fixed golden 產生依據，確保順序與 RTL 一致。

---

#### C.3 Layer 2 目前狀態

已完成：
- `psum_mem` 支援 128 output channels
- ping-pong SRAM offset 擴大到 `0x2A000`
- address offset 寬度修正為 `M_ADDR_WIDTH`
- Pointwise Conv golden generation 更新

---

## 7. SystemVerilog 修改總表

| 檔案 | 修改內容 |
|------|----------|
| `mfn_frontend_top.sv` | 加入 `sram_wr_addr` 1-cycle pipeline delay，使 write address 與 activation valid/data 對齊 |
| `mfn_frontend_top_tb.sv` | `AWIDTH` 從 32 改為 40；加入 debug monitor；支援多層 simulation；修復 `always_ff` 多驅動源問題 |
| `mfn_addr_gen.sv` | `is_pad` 加 1-cycle delay；write address 加 ping-pong offset；offset 從 `0x10000` 調整為 `0x2A000`；`pixel_offset` 改為 `M_ADDR_WIDTH` |
| `mfn_controller.sv` | `load_pixel` / `pixel_idx` 加 1-cycle delay；修正 `STATE_CH_IN_LOOP` 不再重設 PSUM；修正 `STATE_FETCH_PIXELS` 多等 1 cycle；`psum_mem` 擴充至 128 |
| `mfn_mac_array.sv` | 修正 signed multiplication sign extension；加入 MAC pipeline 優化 |
| `mfn_activation.sv` | PReLU 順序改為先 `>>> 10` 再乘 alpha；乘法器從 48-bit 縮至 32-bit |
| `mfn_weight_rom.sv` | 支援多層 weight concatenate 後的 base address 存取 |
| `mfn_layer_config_rom.sv` | 升級為 64-bit config format，支援多層與 layer type control |

---

## 8. Python Script 修改總表

| 檔案 | 修改內容 |
|------|----------|
| `gen_hex.py` | 使用 `golden_weights_fixed/` 的預量化權重；input image 正確 CHW → HWC；修正 config H/W；支援 Layer 0 + Layer 1 權重串接；支援 64-bit config packing |
| `verify_rtl.py` | 從正確 SRAM offset 讀 RTL output；RTL HWC → CHW；支援 `python3 verify_rtl.py <layer_id>` 多層驗證 |
| `gen_pw_golden.py` | 新增 Layer 2 Pointwise Conv fixed golden generation，確保 Quantization / PReLU 順序與 RTL 一致 |

---

## 9. Synthesis 時序優化紀錄

### 9.1 MAC Array Pipeline

**修改前：** 9 個 16×16 multiplier 與 adder tree 全部位於同一條 combinational path，延遲過長。

```
input → 9 multipliers → adder tree → output
```

**修改後：** 加入一級 pipeline register。

```
input → 9 multipliers → register → adder tree → output
```

**效益：** 最長路徑切成兩段，大幅提升可合成頻率；增加 1-cycle latency，但不影響 throughput。

---

### 9.2 Controller Incremental Address Optimization

**修改前：** `weight_addr` 與 `pixel_idx` 計算包含 multiplication、division、modulo（`k % 3`、`k / 3`），造成 combinational logic 過重。

**修改後：**
1. 使用 LUT 取代 kernel spatial offset：`kx_offset[k]`、`ky_offset[k]`
2. 使用 incremental weight addressing：`wgt_addr += wgt_step`
3. 消除 weight address 計算中的組合乘法器

---

### 9.3 Sign Extension Bug Fix

在 `kx_offset` / `ky_offset` 處理 signed padding coordinate 時，修正 sign extension：

```verilog
{{7{kx_offset[1]}}, kx_offset}
```

確保負數 offset 在位寬擴展後仍維持正確 signed value。

---

## 10. Layer 支援狀態

| Layer | Type | Input | Output | 狀態 |
|-------|------|-------|--------|------|
| L0 | Conv1 (3×3 stride 2) | 3×112×96 | 64×56×48 | ✅ 100.00% |
| L1 | DW1 (3×3 stride 1) | 64×56×48 | 64×56×48 | ✅ 100.00% |
| L2–L4 | Block0 (PW1/DW s2/PW2) | 64×56×48 | 64×28×24 | ✅ 100.00% |
| L5–L7 | Block1 (PW1/DW/PW2+Res) | 64×28×24 | 64×28×24 | ✅ 100.00% |
| L8–L16 | Block2–4 (×3, Residual) | 64×28×24 | 64×28×24 | ✅ 100.00% |
| L17–L19 | Block5 (PW1 256ch/DW s2/PW2) | 64×28×24 | 128×14×12 | ✅ 100.00% |
| L20–L37 | Block6–11 (×6, Residual) | 128×14×12 | 128×14×12 | ✅ 100.00% |
| L38–L40 | Block12 (PW1 512ch/DW s2/PW2) | 128×14×12 | 128×7×6 | ✅ 100.00% |
| L41–L46 | Block13–14 (×2, Residual) | 128×7×6 | 128×7×6 | ✅ 100.00% |
| L47 | Conv2 (1×1, 128→512) | 128×7×6 | 512×7×6 | ✅ 100.00% |
| L48 | linear7 (7×6 Global DW) | 512×7×6 | 512×1×1 | ✅ 100.00% |
| L49 | linear1 (1×1, 512→128) | 512×1×1 | 128×1×1 | ✅ 100.00% |

---

## 11. 重要觀察與結論

### 11.1 Layer 0 跑兩層後 match rate 下降不是錯誤

跑完 Layer 0 + Layer 1 後，直接檢查 Layer 0 output，match rate 會下降，原因是 Layer 1 output 透過 ping-pong 寫回另一側 SRAM 並覆蓋舊資料。這是 expected behavior，不代表 Layer 0 計算錯誤。

### 11.2 早期 Layer 0 的 98.5% mismatch 不是單純 accumulator 差異

早期判斷剩餘 mismatch 可能來自 `int32` C-model 與 `int40` RTL accumulator 差異。後來確認還有更關鍵的 bug：`STATE_FETCH_PIXELS` 少等 1 cycle，導致 `window_reg[8]` 使用 stale data。修正後 Layer 0 可達 100.00% Exact Match。

### 11.3 Ping-Pong offset 必須依最大 feature map 大小設計

早期使用 `0x10000` 作為 ping-pong offset，在 Layer 0 單層時足夠，但 Layer 1 output size 為 172,032 entries，已超過 65,536。多層運算時必須使用更大的 ping-pong region（如 `0x2A000 = 172,032`），否則造成 read/write overlap。

---

## 12. 後續工作

### 12.1 Pointwise Conv 效能優化 (已完成)

已實作 `is_pw` mode，使用 9 個 MAC lanes 同時處理 9 個 input channels，SRAM 讀取次數降低 9 倍。

### 12.2 Residual Shortcut 支援 (已完成)

已實作 3-buffer ping-pong 輪轉與 `mfn_activation` 內部的殘差加法邏輯。

### 12.3 Synthesis / Timing 持續優化

後續可繼續檢查：
- MAC adder tree pipeline depth
- ROM read path
- SRAM address generation path
- Controller FSM critical path
- Pointwise Conv channel loop scheduling

---

## 13. 常用指令

### 清除 Xcelium 暫存檔

```bash
cd hardware/frontend/sim
rm -rf xcelium.d xcelium.d.old
rm -f .nfs*
```

若 `.nfs*` 無法刪除：

```bash
lsof .nfs*
kill <PID>
# 若仍無法結束
kill -9 <PID>
```

### 重新產生 HEX 並模擬

```bash
cd hardware/frontend/sim
python3 gen_hex.py
make top
```

### 驗證特定 Layer

```bash
cd ../../..
python3 software/verify_rtl.py 0
python3 software/verify_rtl.py 1
python3 software/verify_rtl.py 2
```

---

## 14. 開發里程碑

| 日期 | 里程碑 | 結果 |
|------|--------|------|
| 2026-04-26 | Layer 0 initial debug | 從 0.51% 提升到 98.50% |
| 2026-04-26 | 修正 window stale data | Layer 0 達到 100.00% |
| 2026-04-26 | Layer 1 Depthwise Conv debug | Layer 1 達到 100.00% Exact Match |
| 2026-04-26 | Multi-layer ping-pong 驗證 | Layer 0 + Layer 1 可連續執行 |
| 2026-04-26 | Layer 2 Pointwise Conv debug | 修正 psum depth、ping-pong collision、address overflow |
| 2026-04-27 | Pointwise 效能優化 | 實作 9-lane 並行讀取，效能提升 ~9x |
| 2026-04-27 | 殘差連接與 3-Buffer | 實作 3-buffer 輪轉與 Resid-Add，Layer 3 驗證成功 |
| 2026-04-27 | Pipeline 時序優化 | MAC Array 加入二級 pipeline，修正控制器 delay 對齊 |
| 2026-04-29 | Config 位元重排 | h/w 8b→7b，wgt_base 18b→20b，bias_addr 10b→14b，psum_mem 擴為 512 |
| 2026-04-29 | gen_hex.py 完整重寫 | 支援全 48 層，總權重 922,176 entries，總 bias 9,152 entries |
| 2026-04-29 | 全 48 層 RTL 驗證通過 | L0–L47 全部 100.00% Exact Match，41,694,006 cycles |
| 2026-04-29 | linear7 Global DW 實作 | L48 100.00% Exact Match，41,724,218 cycles（+30,212 cycles）|
| 2026-04-29 | linear1 全模型完成 | L49 100.00% Exact Match，41,732,515 cycles（+8,297 cycles）|
| 2026-04-30 | Synthesis critical path pipeline 優化 | addr_gen 2-stage, activation 2-stage, 移除 synthesis blocker；43,158,478 cycles (+3.4%)；全 50 層仍 100.00% |

---

## 15. 總結

MobileFaceNet Frontend RTL 已完成全 50 層（L0–L49）的硬體實作與驗證。

**最重要的成果：**

1. **Pointwise (1x1) 卷積優化**：透過 9 通道並行讀取，大幅提升計算效率。
2. **殘差連接 (Residual) 支援**：建立 3-buffer 管理機制，支援 `output = f(input) + shortcut`。
3. **時序與流水線優化**：MAC Array 具備 2-stage pipeline，有利於 100MHz+ 合成。
4. **linear7 Global DW**：5-group × 9-MAC 方案，重用現有 3×3 kernel 路徑支援 7×6 global depthwise conv。
5. **全模型驗證**：Layer 0–49 全部達到 **100.00% Exact Match**，總執行時間 41,732,515 cycles。

**下一階段重點：**
- [ ] **Synthesis 驗證**：在 moore server 上使用 Design Compiler 檢查實時時序 (Timing Closure)。
- [ ] **AXI-Stream / DMA 介面**：目前僅在 TB 內部 SRAM 運作，需接 AXI-Stream 供外部 DMA 存取。

---

## 16. 全網推論進度分析 (2026-04-26)

### 16.1 C 模型總層數分析
根據 `software/c_model/inference_main.c`，MobileFaceNet 總共有 **50 層** 捲積相關運算層：
1. **初始層 (2層)**: `conv1` (Standard), `dw_conv1` (DW)
2. **Bottleneck Blocks (45層)**: 15 個 Block，每個包含 `pw1`, `dw`, `pw2` 三層。
3. **結尾層 (3層)**: `conv2` (Standard), `linear7` (7x6 DW), `linear1` (1x1)
**總計：50 層運算層。**

### 16.2 目前進度
目前 RTL 已驗證 **3 / 50 層 (約 6%)**：
- **Layer 0**: `conv1` (100% 正確)
- **Layer 1**: `dw_conv1` (100% 正確)
- **Layer 2**: `blocks_0_pw1` (100% 正確)

### 16.3 核心挑戰
- **自動化配置**：我們需要自動遍歷 15 個 Block 並產生所有 50 層的 `config.hex` 與 `weights.hex`。
- **殘差邏輯**：從 `blocks_0_pw2`（第 5 層）開始，需要實作從 SRAM 讀取舊資料與新結果相加的邏輯（Shortcut）。
- **特殊 Kernel**：`linear7` 層使用了 7x6 的 Kernel，位址產生器需要確認是否支援。

---

## 17. 綜合瓶頸與性能優化建議 (Synthesis & Pipeline Optimization)

根據目前 RTL 的架構分析，在進行邏輯綜合（Synthesis）時，以下幾個地方最有可能成為 **Timing Bottleneck（關鍵路徑）**，進而限制最高時脈頻率：

### 17.1 潛在的 Synthesis Bottlenecks
1. **位址產生器 (Address Generation) - [最危險]**
   - **位置**：`mfn_addr_gen.sv` 中的 `sram_rd_addr` 計算。
   - **路徑**：`y_in * width_in` $\rightarrow$ `+ x_in` $\rightarrow$ `* in_ch_in` $\rightarrow$ `+ c_in`。
   - **原因**：在一個時脈週期內連續執行兩次乘法與兩次加法，邏輯深度過大。

2. **激活函數與量化 (Activation & Quantization)**
   - **位置**：`mfn_activation.sv`。
   - **路徑**：`Shift` $\rightarrow$ `Clamp1` $\rightarrow$ `Multiplier (16x16)` $\rightarrow$ `Shift` $\rightarrow$ `Clamp2`。
   - **原因**：PReLU 乘法器前後都接了複雜的組合邏輯，若在同一週期完成會嚴重拉低頻率。

3. **控制器狀態機 (Controller FSM)**
   - **位置**：`mfn_controller.sv`。
   - **原因**：`always_comb` 區塊同時處理 Config 解碼、複雜坐標更新與權重位址計算。

### 17.2 建議的 Pipeline 修改方案
- [ ] **[ADDR_GEN] 拆分計算步階**：
  - **Stage 1**: 計算 `pixel_offset = y_in * width_in + x_in` 並存入暫存器。
  - **Stage 2**: 計算 `sram_rd_addr = pixel_offset * in_ch_in + c_in`。
  - *注意：這會增加 1 個週期的讀取延遲，控制器的 load_pixel 相關路徑需同步調整。*
- [ ] **[ACTIVATION] 插入乘法器後級暫存器**：
  - **Cycle 1**: 執行第一階段 Quantize 與 PReLU 乘法。
  - **Cycle 2**: 執行 PReLU 移位與最終的結果選擇與 Clamp。
- [ ] **[CONTROLLER] 預計算權重位址**：
  - 將 `weight_addr` 的計算從 `STATE_CALC_PSUM` 提前到 `STATE_FETCH_PIXELS`，避免與 MAC 計算的路徑重疊。
---

## 18. Phase D：Pointwise 優化、殘差支援與流水線優化 (2026-04-27)

### 18.1 實作內容
1. **Pointwise 9-Lane 並行化**：
   - 修改 `mfn_controller.sv`，在 `is_pw` 模式下，每個 cycle 切換通道（`c_in`），連續讀取 9 個通道像素存入 `mfn_sliding_window`。
   - MAC Array 的 9 個乘法器同時運作，一個 `oc` 迴圈內即可完成 9 個通道的累加。
2. **殘差連接 (Residual Shortcut)**：
   - **3-Buffer 輪轉**：`mfn_addr_gen.sv` 支援三個基底位址。當 `rd_buf=A, wr_buf=B` 時，自動計算 `res_buf = 3 - A - B` 作為殘差來源。
   - **加法邏輯**：在 `mfn_activation.sv` 寫回 SRAM 前，從殘差緩衝區讀出對應像素並相加。
3. **MAC Pipeline**：
   - `mfn_mac_array.sv` 加入二級暫存器。
   - 控制器新增 `calc_psum_d2` 與 `c_out_d2` 訊號，補償 2 個 cycle 的硬體延遲，確保 partial sum 寫回正確的 channel index。

### 18.2 遇到的問題與解決方案

**Problem D1：Pointwise 讀取位址重複 (Address Stale)**
- **現象**：Layer 2 前 9 個通道讀到的都是 Channel 0 的資料。
- **原因**：`c_in_out` 使用了延遲後的 `k_reg_d1`，導致地址產生比預期晚了一拍，且在 `k=0` 與 `k=1` 時地址相同。
- **解決**：將 `c_in_out` 改為直接使用組合邏輯的 `k_reg`。

**Problem D2：通道邊界讀取越界 (OOB Channel Access)**
- **現象**：當 `in_ch=64` 時，9 通道並行讀取會讀到第 64~71 個地址（越界到下一個像素）。
- **原因**：1x1 優化總是固定抓 9 個通道。
- **解決**：在 `mfn_addr_gen.sv` 加入 `c_in >= in_ch_in` 的判斷，強行觸發 `is_pad` 將無效通道像素歸零。

**Problem D3：殘差讀取與寫回衝突**
- **現象**：加法結果數值雜亂。
- **原因**：殘差讀取（SRAM Read）需要 1 cycle，如果與 `inc_write` 同一拍執行，會讀到舊的地址。
- **解決**：在控制狀態機中加入 `STATE_READ_RESIDUAL` 狀態，提前一拍送出地址，確保資料在 `STATE_ADD_RESIDUAL` 時準確抵達。

### 18.3 驗證結果與進度
- **Phase A~C**: 核心卷積運算器完成。
- **Phase D**: Pointwise (1x1) 優化與殘差邏輯初探。
- **Phase E**: 完整 Bottleneck (Block 0+1) 驗證通過。
  - **Layer 0~6**: 100% Match (包含 Stride 2 DW-Conv)。
  - **Layer 7**: 100% Match (首個成功的真實殘差加法層)。

## 19. Phase E: 1MB SRAM 擴展與殘差位址修復 (2026-04-27)

在嘗試驗證第一個完整的 Bottleneck Block (Block 1) 時，遇到了深層網路特有的問題。

### 19.1 遇到的挑戰與解決方案

**Problem E1：SRAM Buffer 空間重疊 (Overlap)**
- **現象**：Layer 3 (Stride 2) 驗證失敗，匹配率僅 78%。
- **原因**：當通道數擴展至 128 時，56x48 的 Feature Map 大小為 344,064 words。原本 512KB (524,288 words) 的 SRAM 分成三個 Buffer (每個約 172k) 完全不夠用。Buffer 2 會寫入 Buffer 1 的讀取空間，造成資料損毀。
- **解決**：
  - 將硬體地址位寬從 **19-bit 提升至 20-bit** (支援 1MW SRAM)。
  - Buffer Offset 從 `0x2A000` 擴大至 **`0x54000`** (344,064 點)，確保 128-ch 層有獨立不重疊的空間。

**Problem E2：殘差讀取位址計算錯誤**
- **現象**：Layer 7 (Residual) 匹配率趨近於 0。
- **原因**：`mfn_addr_gen` 原本固定使用 `in_ch_in` 計算讀取位址。但在 Layer 7 (Projection)，輸入通道是 128，而殘差 Buffer (來自 Layer 4) 只有 64 通道。使用 128 去算殘差位址會導致取錯像素。
- **解決**：在 `mfn_addr_gen.sv` 引入 `out_ch_in`。當 `read_res` 為高時，強制改用 `out_ch_in` (即殘差層的通道數) 進行位址換算。

**Problem E3：殘差 Buffer 覆寫防範**
- **現象**：殘差加法的對象被中間層覆蓋。
- **解決**：調整 `gen_hex.py` 中的 Buffer 輪轉。在 Block 1 中，Layer 6 (DW) 寫入 **Buffer 0**，保留 **Buffer 1** 中的原始輸入給 Layer 7 (Proj) 使用。

### 19.2 總結
這是一個重大的里程碑。我們成功驗證了 **MobileFaceNet NPU 前端** 的所有核心功能：

1.  **Pointwise Conv (1x1) 效能優化**：在 Layer 2 驗證成功，支援 9-channel 並行讀取。
2.  **Residual Shortcut (殘差加法)**：在 Layer 7 驗證成功，正確實作了跨 Buffer 的像素加法。
3.  **Stride 2 與深度卷積 (DW-Conv)**：在 Layer 0 與 Layer 3 驗證成功。
4.  **3-Buffer 記憶體管理**：透過將 SRAM 擴展至 1MB 並修正 Buffer 輪轉邏輯，解決了 128 通道層導致的記憶體重疊與覆寫問題。

### 19.3 驗證結果摘要

| 層級 | 類型 | 輸出維度 (C,H,W) | 匹配率 (Exact) | 備註 |
| :--- | :--- | :--- | :--- | :--- |
| **Layer 0** | Conv1 | (64, 56, 48) | **100.00%** | Stride 2 |
| **Layer 1** | DW1 | (64, 56, 48) | **100.00%** | |
| **Layer 2** | PW1 | (128, 56, 48) | **100.00%** | Pointwise 優化 |
| **Layer 3** | DW2 | (128, 28, 24) | **100.00%** | Stride 2 |
| **Layer 4** | PW2 | (64, 28, 24) | **100.00%** | Linear (無 PReLU) |
| **Layer 5** | PW3 | (128, 28, 24) | **100.00%** | |
| **Layer 6** | DW3 | (128, 28, 24) | **100.00%** | |
| **Layer 7** | PW4 | (64, 28, 24) | **100.00%** | **Residual Shortcut** |

### 19.4 核心更動紀錄

-   **mfn_addr_gen.sv**: 
    -   將 M_ADDR_WIDTH 提升至 **20-bit** (支援 1MW SRAM)。
    -   修正 Buffer Offset 為 `0x54000` (344,064 words)，確保 128 通道層有足夠空間。
    -   新增 `out_ch_in` 輸入，修正殘差讀取時的位址計算（當輸入與殘差通道數不同時）。
-   **mfn_frontend_top_tb.sv**: 同步更新 SRAM 模型大小與存檔邏輯。
*   **gen_hex.py**: 更新 Buffer 輪轉順序（Layer 6 改寫入 Buffer 0），避免在殘差加法前覆寫原始輸入 (Buffer 1)。
*   **verify_rtl.py**: 更新至支援 8 層自動化比對。

## 20. 下一步工作 (2026-04-29 更新前)

1. **全網路配置自動化**：開發指令碼從 PyTorch/ONNX 直接提取 50 餘層的權重與 Config，生成完整的 `config.hex` 與 `weights.hex`。
2. **多 Buffer 策略優化**：考慮加入更智慧的 Buffer 分配算法，以支援更高解析度或更深通道的 Feature Maps。
3. **前端系統整合**：目前僅在 TB 運作，需準備 AXI-Stream 接口與外部 DMA 接軌。

---

## 21. Phase F：全網路擴展 L0–L47 (2026-04-29)

### 21.1 目標

將 RTL 模擬從已驗證的 **8 層 (L0–L7)** 擴展至完整的 **48 層 (L0–L47)**，涵蓋：
- Conv1, DW1
- 15 個 Bottleneck Block（Blocks 0–14）
- Conv2

> **不包含** `linear7`（7×6 global DW，硬體 3×3 sliding window 無法支援）與 `linear1`（1×1 FC 層）。

---

### 21.2 RTL 修改：位址空間擴展

#### 問題根因

| 問題 | 說明 |
|------|------|
| `wgt_base` 只有 18-bit | 48 層總權重 922,176 entries，超過 18-bit 上限 262,144 |
| `bias_addr` 只有 10-bit | 9,152 bias entries 超過 10-bit 上限 1,024 |
| `psum_mem` 深度為 128 | Block 12 PW1 output channel 達 512，超出索引範圍 |
| `wgt_step` in_ch=512 寫錯 | 原為 `18'd522`，正確為 `18'd513`（ceil(512/9)×9）|

#### 解法：Config 位元重排

原有 `h/w` 欄位各 8-bit（上限 255），但實際最大值為 112/96，7-bit（上限 127）已足夠。  
縮減 h/w 各 1-bit，釋出 2-bit 給 `wgt_base`，使其從 18-bit 擴展為 **20-bit**。

**新 64-bit Config 格式：**

```
[9:0]   in_ch      (10-bit)
[19:10] out_ch     (10-bit)
[26:20] w          (7-bit)   ← 縮減 1-bit
[33:27] h          (7-bit)   ← 縮減 1-bit
[35:34] stride     (2-bit)
[36]    has_prelu  (1-bit)
[37]    is_res     (1-bit)
[38]    is_pw      (1-bit)
[39]    is_dw      (1-bit)
[59:40] wgt_base   (20-bit)  ← 從 18-bit 擴展
[61:60] rd_buf     (2-bit)
[63:62] wr_buf     (2-bit)
```

#### 修改的 RTL 檔案

| 檔案 | 修改內容 |
|------|----------|
| `mfn_controller.sv` | `wgt_base` 18→20-bit；`bias_addr`/`bias_base_reg` 10→14-bit；`psum_mem` 深度 128→512；修正 `wgt_step` in_ch=512 為 `18'd513`；停止條件改為 `layer_idx_reg >= 6'd47` |
| `mfn_weight_rom.sv` | addr 18→20-bit；mem 大小 262,144→1,048,576 |
| `mfn_bias_rom.sv` | addr 10→14-bit；mem 大小 1,024→16,384 |
| `mfn_prelu_rom.sv` | addr 10→14-bit；mem 大小 1,024→16,384 |
| `mfn_frontend_top.sv` | `img_w`/`img_h` 8→7-bit；`weight_addr`/`bias_addr` 更新；Config decode 欄位同步更新 |
| `mfn_addr_gen.sv` | `width_in`/`height_in` 8→7-bit |

---

### 21.3 Software 修改

#### `hardware/frontend/sim/gen_hex.py`（完整重寫）

- 新增 `make_config()` 函式，對應新的 64-bit 位元佈局
- 載入全部 48 層的 weight / bias / PReLU（blocks_0–blocks_14、conv2）
- 正確計算各層 PW weight packing：`wgt_step = ceil(in_ch/9) * 9`
- 輸出：`weights.hex`（922,176 entries，< 2²⁰）、`bias.hex`（9,152 entries，< 2¹⁴）、`config.hex`（48 entries）
- 含 assertion 驗證不超出位址空間

**Buffer 輪轉策略（全 48 層）：**

三個 Buffer（B0=0x00000，B1=0x54000，B2=0xA8000，各 344,064 words），  
`res_buf = 3 - rd_buf - wr_buf` 自動為 DW 層保留 residual source。

| Layer 範圍 | 說明 | wr_buf |
|-----------|------|--------|
| L0 Conv1 | rd=B0, wr=B1 | B1 |
| L1 DW1 | rd=B1, wr=B2 | B2 |
| L2–L4 Block0 | PW1/DW/PW2 輪轉 B1/B2/B1 | — |
| L5–L7 Block1 | PW1→B2, DW→B0, PW2+Res→B2 | B2 |
| L8–L47 | 繼續按 (rd,wr) = cyclic 三輪 | 依層決定 |
| L47 Conv2 | rd=B2, wr=B1 | B1 |

#### `software/gen_all_golden.py`（新增 L8–L47）

新增兩個向量化函式以加速大通道層（256ch、512ch）的 golden 計算：

```python
def pw_conv_fast(inp, wgt, bias, alpha, has_prelu):
    # 矩陣乘法實作 1×1 conv，全 spatial 位置一次計算
    # W(c_out,c_in) @ I(c_in,h*w) → Q20 >> 10 → clamp → PReLU

def dw_conv_fast(inp, wgt, bias, alpha, stride, has_prelu):
    # 對 3×3 kernel 展開 loop（9次），向量化 channel 維度
    # 使用 int64 防止 overflow
```

Residual addition 使用正確的 int32 中間型別後 clamp：

```python
def res_add(a, b):
    return np.clip(a.astype(np.int32) + b.astype(np.int32), -32768, 32767).astype(np.int16)
```

新增 `bottleneck_fast(inp, name, c_mid, c_out, stride, l_start)` 統一處理每個 Block 的 PW1→DW→PW2 三層。

#### `hardware/frontend/sv/mfn_frontend_top_tb.sv`（更新）

- `case (layer_idx)` 擴展至 L0–L47，每層完成後 `$writememh` 存一份 SRAM snapshot
- 停止條件從 `layer_idx == 7` 改為 `layer_idx == 6'd47`
- 移除僅用於 debug 的冗長 `$display` 輸出

#### `software/verify_rtl.py`（更新）

新增 `LAYER_PARAMS` 中全部 48 層的輸出維度與 SRAM offset：

| 層級 | (C, H, W) | offset |
|------|-----------|--------|
| L0 | (64, 56, 48) | B1 |
| L3 | (128, 28, 24) | B2 |（stride 2）|
| L17 | (256, 28, 24) | B2 |（64→256 expansion）|
| L18 | (256, 14, 12) | B0 |（stride 2）|
| L38 | (512, 14, 12) | B1 |（128→512 expansion）|
| L39 | (512, 7, 6) | B0 |（stride 2）|
| L47 | (512, 7, 6) | B1 |（Conv2）|
| … | … | … |

---

### 21.4 驗證結果

```
=== 全 48 層 100.00% Exact Match ===
總執行時間：41,694,006 cycles
```

| Layer | 類型 | 輸出 (C,H,W) | 結果 |
|-------|------|-------------|------|
| 0 | Conv1 | (64,56,48) | ✅ 100% |
| 1 | DW1 | (64,56,48) | ✅ 100% |
| 2–4 | Block0 | 64ch, 28×24 | ✅ 100% |
| 5–7 | Block1 | 64ch, 28×24 | ✅ 100% |
| 8–16 | Block2–4 | 64ch, 28×24 | ✅ 100% |
| 17 | B5-PW1 | (256,28,24) | ✅ 100% |
| 18 | B5-DW | (256,14,12) | ✅ 100% |
| 19–37 | Block5–11 | 128ch, 14×12 | ✅ 100% |
| 38 | B12-PW1 | (512,14,12) | ✅ 100% |
| 39 | B12-DW | (512,7,6) | ✅ 100% |
| 40–46 | Block12–14 | 128ch, 7×6 | ✅ 100% |
| 47 | Conv2 | (512,7,6) | ✅ 100% |

---

### 21.5 驗證步驟（完整流程）

```bash
# Step 1：產生 HEX（從 sim 目錄執行）
cd hardware/frontend/sim
python3 gen_hex.py

# Step 2：產生全部 Golden
cd ../../..
python3 software/gen_all_golden.py

# Step 3：RTL 模擬（Xcelium）
cd hardware/frontend/sim
make top

# Step 4：逐層比對
cd ../../..
for i in $(seq 0 47); do python3 software/verify_rtl.py $i; done
```

---

## 22. Phase G：linear7 Global DW Conv 實作 (2026-04-29)

### 22.1 設計挑戰

`linear7` 使用 7×6=42 tap depthwise kernel，但現有硬體只有：
- 9-slot sliding window（`mfn_sliding_window`）
- 9-element MAC array（`mfn_mac_array`）
- 3×3 kernel addressing（`kx_offset/ky_offset` LUT）

直接擴展 kernel 大小代價高昂（需要大量修改且影響 timing）。

---

### 22.2 設計決策：5-Group × 9-MAC 方案

**核心思路：** 將 42 個 kernel tap 分成 5 組，每組 9 個（最後一組僅 6 個有效，3 個補 0），重用現有 9-MAC 陣列，每次 STATE_FETCH_PIXELS 載入 1 組，連續執行 5 次累加後再進行 write-back。

```
Group 0: tap  0– 8  → k_global  0.. 8  → (ky,kx) valid
Group 1: tap  9–17  → k_global  9..17  → (ky,kx) valid
Group 2: tap 18–26  → k_global 18..26  → (ky,kx) valid
Group 3: tap 27–35  → k_global 27..35  → (ky,kx) valid
Group 4: tap 36–44  → k_global 36..44  → 36..41 valid, 42..44 OOB → is_pad → ×0
```

---

### 22.3 Config Encoding：is_pw && is_dw

64-bit config 位元已全部用完。注意到 `is_pw=1 && is_dw=1` 在原有 48 層中從未同時出現（pointwise 與 depthwise 是互斥的），因此將此組合重新定義為 **global DW** 模式：

```systemverilog
logic is_global_dw;
assign is_global_dw = layer_is_pw & layer_is_dw;
```

L48 config 設定：`make_config(..., is_pw=1, is_dw=1, ...)`

---

### 22.4 Controller 修改（mfn_controller.sv）

#### 新增暫存器與 LUT

```systemverilog
logic [2:0] group_idx_reg, group_idx_next;  // 追蹤目前是第幾組 (0–4)

// gdw_lut: 計算 k_global_comb = group_base + k_reg
// → (gdw_ky = k_global / 6, gdw_kx = k_global % 6)
// k_global >= 42 → OOB → is_pad → zero multiply
always_comb begin : gdw_lut
    case (group_idx_reg)
        3'd0: group_base = 6'd0;
        3'd1: group_base = 6'd9;
        3'd2: group_base = 6'd18;
        3'd3: group_base = 6'd27;
        3'd4: group_base = 6'd36;
        default: group_base = 6'd0;
    endcase
    k_global_comb = group_base + {2'b0, k_reg};
    if (k_global_comb < 6'd42) begin
        gdw_ky = k_global_comb / 4'd6;
        gdw_kx = k_global_comb % 4'd6;
    end else begin
        gdw_ky = 4'd7;   // OOB → addr_gen 觸發 is_pad
        gdw_kx = 4'd6;
    end
end
```

#### x_out / y_out 多路選擇

```systemverilog
assign x_out = is_global_dw ? $signed({5'b0, gdw_kx})
                            : (x_reg + {{7{kx_offset[1]}}, kx_offset});
assign y_out = is_global_dw ? $signed({5'b0, gdw_ky})
                            : (y_reg + {{7{ky_offset[1]}}, ky_offset});
```

#### STATE_FETCH_PIXELS：group > 0 不重置 wgt_addr

```systemverilog
if (!is_global_dw || group_idx_reg == 3'd0)
    wgt_addr_next = wgt_cin_base_reg;  // 只有第一組才 reset weight pointer
```

#### STATE_CALC_PSUM：5-group 流程控制

```systemverilog
if (is_global_dw) begin
    if (group_idx_reg == 3'd4) begin
        group_idx_next = '0;
        state_next = STATE_MAC_FLUSH;   // 所有 5 組都完成 → flush
    end else begin
        group_idx_next = group_idx_reg + 1'b1;
        state_next = STATE_FETCH_PIXELS; // 繼續下一組
    end
end
```

#### wgt_cin_base 每 channel 前進步長

```systemverilog
// Global DW 每 channel 佔 45 entries (5 groups × 9)；Regular DW 佔 9
wgt_cin_base_next = wgt_cin_base_reg + (is_global_dw ? 18'd45 : 18'd9);
```

#### STATE_SPATIAL_LOOP：global DW 直接跳到 NEXT_LAYER

Global DW output 永遠是 1×1，spatial 迴圈只有一個位置，但 layer_h=7、layer_w=6 是 **input** 維度，如果照標準空間迴圈走會錯誤地迭代 7×6 次：

```systemverilog
if (is_global_dw) begin
    state_next = STATE_NEXT_LAYER;  // 直接結束，無 spatial 迭代
end else begin
    // 標準 x/y 邊界判斷
end
```

#### 停止條件

```systemverilog
// 原本 >= 6'd47 改為 >= 6'd48
if (layer_idx_reg >= 6'd48) state_next = STATE_IDLE;
```

---

### 22.5 gen_hex.py 修改

新增 `pack_global_dw_weights()` 函式：

```python
def pack_global_dw_weights(wgt_raw, channels, kh, kw):
    taps = kh * kw                       # 42 for 7×6
    group_size = ((taps + 8) // 9) * 9  # 45 (5 groups × 9, last group zero-padded)
    packed = []
    for c in range(channels):
        ch_weights = wgt_raw[c * taps : (c + 1) * taps]
        for w in ch_weights: packed.append(w)
        for _ in range(group_size - taps): packed.append(0)  # padding to 45
    return packed
```

L48 config 行：
```python
make_config(512, 512, 6, 7, 1, 0, 0, 1, 1, wb[48], 1, 0)
# (in_ch, out_ch, w, h, stride, has_prelu, is_res, is_pw, is_dw, wgt_base, rd_buf, wr_buf)
```

Weight 統計：
- L47 之前：922,176 entries（wgt_base < 2²⁰ ✅）
- 加入 L48（512 ch × 45）= +23,040 entries → 總計 **945,216 entries**
- Bias 加入 L48（512 entries）= +512 → 總計 **9,664 entries**

---

### 22.6 gen_all_golden.py 修改

```python
# L48: linear7 (global DW, 7×6 kernel, 512ch, no PReLU)
l48_wgt = load_fixed("linear7_weight.txt")   # 512 * 42 = 21,504 entries
l48_bias = load_fixed("linear7_bias.txt")    # 512 entries
wgt48 = np.array(l48_wgt).reshape(512, 1, 7, 6).astype(np.int64)
bias48 = np.array(l48_bias).astype(np.int64)
inp48 = l47[0].astype(np.int64)              # (512, 7, 6)  ← 注意用 l47，不是 cur

out48 = np.zeros((512,), dtype=np.int64)
for c in range(512):
    acc = bias48[c]
    for kh in range(7):
        for kw in range(6):
            acc += inp48[c, kh, kw] * wgt48[c, 0, kh, kw]
    out48[c] = int(np.clip(acc >> 10, -32768, 32767))

l48 = out48.reshape(1, 512, 1, 1).astype(np.int16)
```

> **Bug fix**：最初誤用 `cur[0]`（Block 14 output，128ch）作為 L48 輸入，導致 `IndexError: index 128 out of bounds for axis 0 with size 128`。正確來源應為 `l47[0]`（Conv2 output，512ch）。

---

### 22.7 testbench & verify_rtl.py 修改

**mfn_frontend_top_tb.sv**：
- 新增 `6'd48: $writememh("hex/rtl_out_layer48.hex", sram_mem);`
- 停止條件從 `layer_idx == 6'd47` 改為 `layer_idx == 6'd48`
- 完成訊息更新為「All 49 layers complete (L0–L48)」

**verify_rtl.py**：
- 新增 `48: {"C": 512, "H": 1, "W": 1, "offset": B0}`

---

### 22.8 驗證結果

```
=== Layer 48 Verification ===
Comparing 512 pixels (C=512, H=1, W=1)
Exact match:  100.00% (512/512)
Mean abs err: 0.00
Max abs err:  0
```

L0–L48 全 49 層均達 **100.00% Exact Match**。  
總執行時間：**41,724,218 cycles**（linear7 增加約 30,212 cycles）

---

## 23. Phase H：linear1 全模型完成 (2026-04-29)

### 23.1 linear1 層特性

| 項目 | 數值 |
|------|------|
| 類型 | 1×1 Pointwise Conv |
| Input | 512×1×1（來自 linear7 L48 output，wr_buf=B0）|
| Output | 128×1×1 |
| in_ch | 512 |
| out_ch | 128 |
| Spatial | 1×1 |
| PReLU | 無 |
| Residual | 無 |
| wgt_step | ceil(512/9)×9 = 57×9 = 513（已有）|

此層可直接套用現有 PW 路徑，不需任何 RTL 修改。

---

### 23.2 修改的檔案

#### `hardware/frontend/sv/mfn_controller.sv`

```systemverilog
// 停止條件：>= 6'd48 → >= 6'd49
if (layer_idx_reg >= 6'd49) begin  // Stop after Layer 49 (linear1)
    state_next = STATE_DONE;
```

#### `hardware/frontend/sim/gen_hex.py`

```python
# L49: linear1 (1x1 PW, 512->128, no PReLU)
w49 = pack_pw_weights(load_fixed("linear1_weight.txt"), 128, 512)
b49 = load_fixed("linear1_bias.txt")
p49 = [0]*128

# L49 config: rd=B0 (linear7 output), wr=B1, w=1, h=1
make_config(512, 128, 1, 1, 1, 0, 0, 1, 0, wb[49], 0, 1)
```

Weight 統計：
- 加入 L49（128 ch × 513）= +65,664 entries → 總計 **1,010,880 entries**（20-bit max: 1,048,576 ✅）
- Bias 加入 L49（128 entries）= +128 → 總計 **9,792 entries**（14-bit max: 16,384 ✅）

#### `software/gen_all_golden.py`

```python
# L49: linear1 (1x1 PW, 512->128, no PReLU)
wgt49 = np.array(l49_wgt).reshape(128, 512).astype(np.int64)
inp49 = l48[0, :, 0, 0].astype(np.int64)  # (512,)

for oc in range(128):
    acc = bias49[oc] + np.sum(inp49 * wgt49[oc])
    out49[oc] = int(np.clip(acc >> 10, -32768, 32767))
```

#### `hardware/frontend/sv/mfn_frontend_top_tb.sv`

- 新增 `6'd49: $writememh("hex/rtl_out_layer49.hex", sram_mem);`
- 停止條件從 `layer_idx == 6'd48` 改為 `layer_idx == 6'd49`
- 完成訊息更新為「All 50 layers complete (L0–L49)」

#### `software/verify_rtl.py`

- 新增 `49: {"C": 128, "H": 1, "W": 1, "offset": B1}`

---

### 23.3 驗證結果

```
=== Layer 49 Verification ===
Comparing 128 pixels (C=128, H=1, W=1)
Exact match:  100.00% (128/128)
Mean abs err: 0.00
Max abs err:  0
```

**MobileFaceNet Frontend RTL 全 50 層（L0–L49）100.00% Exact Match。**  
總執行時間：**41,732,515 cycles**

---

## 24. Phase I：Synthesis 前 Critical Path Pipeline 優化 (2026-04-30)

### 24.1 背景與動機

全 50 層驗證通過後，下一步是送入 Design Compiler 進行邏輯合成。在合成前，識別並修正下列會造成 timing violation 的 combinational critical path：

1. **`mfn_addr_gen.sv` 雙乘法 critical path**：在單一 cycle 內連續執行 `y×W + x` 與 `×in_ch + c` 兩次乘法，是最長的組合邏輯路徑。
2. **`mfn_activation.sv` PReLU + Residual critical path**：FF-to-FF 路徑包含 `shift → clamp → 16×16 multiply → shift → MUX → add → clamp`，延遲過長。
3. **`mfn_frontend_top.sv` synthesis blocker**：`always @(posedge clk) $display(...)` 引用了 hierarchical path `u_ctrl.state_reg`（Design Compiler 無法跨層次引用），且 `integer l1_calc_cnt = 0` 的初始值在合成時會被忽略，為必修項目。

---

### 24.2 修改一：移除 Synthesis Blocker（`mfn_frontend_top.sv`）

**刪除整段 debug block：**

```systemverilog
// 刪除前（約 8 行）：
integer l1_calc_cnt = 0;
always @(posedge clk) begin
    if (dut.u_ctrl.state_reg == STATE_CALC_PSUM) begin
        l1_calc_cnt++;
        $display("[DEBUG] CALC_PSUM #%0d ...", l1_calc_cnt, ...);
    end
end
```

**原因：**
- `u_ctrl.state_reg`：hierarchical reference，Design Compiler 不支援
- `integer l1_calc_cnt = 0`：initial value 合成時忽略，初始值為 X
- `$display`：simulation-only system task，合成工具報 warning/error

**同步修改：** 將 `sram_wr_addr` 延遲由 1 cycle 擴展為 **2 cycle**，以對齊 `mfn_activation.sv` 新增的 2-stage pipeline（原為 1-cycle，現為 2-cycle latency）：

```systemverilog
logic [M_ADDR_WIDTH-1:0] sram_wr_addr_raw;
logic [M_ADDR_WIDTH-1:0] sram_wr_addr_r1;   // 新增第二個暫存級

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sram_wr_addr_r1 <= '0;
        sram_wr_addr    <= '0;
    end else begin
        sram_wr_addr_r1 <= sram_wr_addr_raw;
        sram_wr_addr    <= sram_wr_addr_r1;
    end
end
```

---

### 24.3 修改二：addr_gen 2-Stage Pipeline（`mfn_addr_gen.sv`）

**舊設計（single-cycle combinational）：**

```
ctrl inputs (y, x, c, ch) → [comb] y×W+x → ×ch+c → sram_rd_addr
```

**新設計（2-stage pipelined）：**

```
Stage 1 register: pixel_offset = y×W+x, ch, c, rd_base
Stage 2 comb:     calc_rd_addr = pixel_offset × ch + c
```

**新增 registers：**

```systemverilog
logic signed [M_ADDR_WIDTH-1:0] pixel_offset_s1;
logic [9:0]                      ch_s1;
logic [9:0]                      c_s1;
logic [M_ADDR_WIDTH-1:0]         rd_base_s1;

always_ff @(posedge clk or negedge rst_n) begin
    pixel_offset_s1 <= $signed(y_in) * $signed({1'b0, width_in}) + $signed(x_in);
    ch_s1           <= read_res ? out_ch_in : in_ch_in;
    c_s1            <= c_in;
    rd_base_s1      <= rd_base;
end

always_comb begin
    calc_rd_addr = M_ADDR_WIDTH'($signed(pixel_offset_s1) * $signed({1'b0, ch_s1})
                                 + $signed({1'b0, c_s1}));
end
assign sram_rd_addr = rd_base_s1 + calc_rd_addr;
```

**`is_pad` 也延遲 2 cycle** 以與新的 2-cycle 地址 pipeline 對齊：

```systemverilog
// is_pad_comb → is_pad_s1 (FF) → is_pad_reg (FF) → assign is_pad
always_ff @(posedge clk or negedge rst_n) begin
    is_pad_s1  <= is_pad_comb;
    is_pad_reg <= is_pad_s1;
end
assign is_pad = is_pad_reg;
```

同時移除 `always_comb` 上不應存在的 `automatic` 關鍵字（synthesis 工具不支援 automatic storage class 在 always_comb）。

---

### 24.4 修改三：activation 2-Stage Pipeline（`mfn_activation.sv`）

**舊設計（single FF stage）：**

```
p_out → [comb] shift→clamp→PReLU_mul→shift→MUX→res_add→clamp → [FF] → pixel_out
```

**新設計（2-stage pipeline）：**

```
Stage 1 register: shift + clamp
Stage 2 register: PReLU_mul + shift + MUX + res_add + clamp
```

**Stage 1 registers：**

```systemverilog
logic signed [DWIDTH-1:0] clamped_s1;
logic                     has_prelu_s1, layer_is_res_s1, valid_s1;
logic signed [DWIDTH-1:0] prelu_w_s1, residual_s1;

always_ff @(posedge clk or negedge rst_n) begin
    clamped_s1      <= clamped;         // shift+clamp 結果
    has_prelu_s1    <= has_prelu;
    prelu_w_s1      <= prelu_w;
    layer_is_res_s1 <= layer_is_res;
    residual_s1     <= residual_in;
    valid_s1        <= valid_in;
end
```

**Stage 2 comb + register：**

```systemverilog
assign prelu_prod    = $signed(clamped_s1) * $signed(prelu_w_s1);
assign prelu_shifted = prelu_prod >>> F_BITS;

always_comb begin
    if (has_prelu_s1 && (clamped_s1 < 0))
        result_raw = prelu_shifted;
    else
        result_raw = clamped_s1;
    if (layer_is_res_s1)
        result_raw = result_raw + residual_s1;
    // clamp to int16
end

always_ff @(posedge clk or negedge rst_n) begin
    if (valid_s1) out_reg <= result;
    valid_reg <= valid_s1;
end
```

---

### 24.5 Controller 配套修改（`mfn_controller.sv`）

addr_gen pipeline 新增 1 cycle latency，activation 新增 1 cycle latency，控制器需對應調整。

#### 24.5.1 State Enum 擴展

state enum 從 `logic [3:0]`（15 states，1 spare）擴充為 `logic [4:0]`（17 states）以容納 2 個新 state：

```systemverilog
typedef enum logic [4:0] {
    STATE_IDLE, STATE_LOAD_CFG, STATE_WAIT_CFG, STATE_INIT_PSUM,
    STATE_FETCH_PIXELS, STATE_CALC_PSUM, STATE_MAC_FLUSH, STATE_MAC_FLUSH_2,
    STATE_CH_IN_LOOP, STATE_READ_RESIDUAL,
    STATE_READ_RESIDUAL_WAIT,   // ← 新增：addr_gen pipeline drain
    STATE_ADD_RESIDUAL, STATE_WRITE_BACK, STATE_SPATIAL_LOOP,
    STATE_NEXT_LAYER_WAIT,      // ← 新增：activation pipeline flush
    STATE_NEXT_LAYER, STATE_DONE
} state_t;
```

#### 24.5.2 load_pixel / pixel_idx：d1 → d2

addr_gen 多 1 cycle latency，SRAM 資料到達 sliding window 需多等 1 cycle：

```systemverilog
// 改為 2-stage delay
logic [3:0] k_reg_d1, k_reg_d2;
logic       load_pixel_d1, load_pixel_d2;

always_ff @(posedge clk or negedge rst_n) begin
    k_reg_d1      <= k_reg;          k_reg_d2      <= k_reg_d1;
    load_pixel_d1 <= load_pixel_comb; load_pixel_d2 <= load_pixel_d1;
end
assign pixel_idx  = k_reg_d2;
assign load_pixel = load_pixel_d2;
```

#### 24.5.3 FETCH_PIXELS：增加 1 個 drain cycle

因 addr_gen 多 1 cycle，k=8 的 pixel 需再多等 1 cycle 才進入 sliding window。增加 k=9 作為空 drain cycle：

```systemverilog
// 舊：k < 9 送地址，k == 9 切到 CALC_PSUM
// 新：k < 9 送地址，k == 9 drain，k == 10 切到 CALC_PSUM
if (k_reg < 4'd9) begin
    load_pixel_comb = 1; k_next = k_reg + 1;
end else if (k_reg == 4'd9) begin
    load_pixel_comb = 0; k_next = k_reg + 1; // 設定 wgt_addr
end else begin
    load_pixel_comb = 0; k_next = '0;
    state_next = STATE_CALC_PSUM;
end
```

#### 24.5.4 STATE_READ_RESIDUAL_WAIT：修正殘差地址 pipeline

**Bug**：addr_gen Stage 1 在 `STATE_READ_RESIDUAL` cycle 捕捉的是前一個 `STATE_WRITE_BACK` 的 non-residual 輸入（read buffer 未更新），導致殘差地址計算錯誤。

**修正**：`STATE_READ_RESIDUAL` 設定 `read_res=1`，新增 `STATE_READ_RESIDUAL_WAIT` 讓 addr_gen Stage 1 以正確的 residual 輸入計算一次，`STATE_ADD_RESIDUAL` 才讀到正確的殘差地址：

```systemverilog
// read_res 涵蓋兩個 state
assign read_res = (state_reg == STATE_READ_RESIDUAL)
                || (state_reg == STATE_READ_RESIDUAL_WAIT);

// FSM transitions
STATE_READ_RESIDUAL:      state_next = STATE_READ_RESIDUAL_WAIT;
STATE_READ_RESIDUAL_WAIT: state_next = STATE_ADD_RESIDUAL;
```

#### 24.5.5 STATE_NEXT_LAYER_WAIT：修正最後一個 pixel 的 SRAM dump 時序

**Bug**：2-stage activation 使 `valid_out` 比 `inc_write` 晚 2 cycle。Testbench 的 `$writememh` 在 `state_reg == STATE_NEXT_LAYER` 時觸發，但最後一個 pixel 的 NBA write 比 `STATE_NEXT_LAYER` 晚 1 cycle 到達，導致每層最後一個 pixel 被 dump 為 0。

**修正**：在 `STATE_SPATIAL_LOOP` 最後一個位置的 transition 改為先進入 `STATE_NEXT_LAYER_WAIT`，讓 activation Stage 2 flush 完畢後（SRAM write NBA 在此 edge 生效），再進 `STATE_NEXT_LAYER` 觸發 `$writememh`：

```systemverilog
// STATE_SPATIAL_LOOP 最後位置（原：state_next = STATE_NEXT_LAYER）
state_next = STATE_NEXT_LAYER_WAIT;

// 新增 state
STATE_NEXT_LAYER_WAIT: state_next = STATE_NEXT_LAYER;
```

---

### 24.6 驗證結果

| 項目 | 數值 |
|------|------|
| 全 50 層驗證 | **100.00% Exact Match（L0–L49）** |
| 總執行週期 | **43,158,478 cycles**（+3.4% vs 原 41,732,515） |

週期增加來源：
- 每次 `STATE_FETCH_PIXELS` 多 1 個 drain cycle
- 每個 residual layer 多 1 個 `STATE_READ_RESIDUAL_WAIT` cycle
- 每層結尾多 1 個 `STATE_NEXT_LAYER_WAIT` cycle
- 2-stage activation 本身增加 1 cycle latency（最後一個 pixel flush）

---

### 24.7 修改檔案總表

| 檔案 | 修改內容 |
|------|----------|
| `mfn_frontend_top.sv` | 移除 debug block（synthesis blocker）；`sram_wr_addr` delay 從 1 cycle 擴為 2 cycle |
| `mfn_addr_gen.sv` | 移除 `automatic` 關鍵字；`is_pad` 雙級暫存；新增 Stage 1 register（pixel_offset, ch, c, rd_base）；Stage 2 combinational multiply |
| `mfn_activation.sv` | 重構為 2-stage pipeline：Stage 1 = shift+clamp，Stage 2 = PReLU×MUX+residual+clamp |
| `mfn_controller.sv` | state enum 從 4-bit 擴為 5-bit；新增 `STATE_READ_RESIDUAL_WAIT` 與 `STATE_NEXT_LAYER_WAIT`；load_pixel/pixel_idx 改為 d2；FETCH_PIXELS 新增 drain cycle（k=9）；read_res 與 c_in_out 涵蓋 WAIT state |

---

## 25. 下一步 TODO（2026-04-30 更新）

### 硬體功能

- [x] **`linear7` 支援**：5-group global DW 模式，L48 達 100.00% Exact Match。
- [x] **`linear1` 支援**：1×1 PW conv（512→128），L49 達 100.00% Exact Match。
- [x] **全 50 層完整驗證**：L0–L49 全部 100.00% Exact Match。
- [x] **Synthesis 前 critical path pipeline 優化**：addr_gen 2-stage、activation 2-stage、移除 synthesis blocker，43,158,478 cycles (+3.4%)。

### 時序優化（Synthesis）

- [ ] **Design Compiler 跑 timing report**：使用 moore server 上的 DC，設定 100MHz clock，確認 setup/hold violation 是否消除。
- [ ] **Area / Power 報告**：取得合成後面積（cell count、NAND2 equivalent）與靜態功耗數字。

### 系統整合

- [ ] **AXI-Stream / DMA 介面**：目前僅在 TB 內部 SRAM 運作，需接 AXI-Stream 供外部 DMA 存取 feature map。
- [ ] **多組測試向量**：目前只驗證一張 112×96 input image，補充多組測試向量以提高覆蓋率。


