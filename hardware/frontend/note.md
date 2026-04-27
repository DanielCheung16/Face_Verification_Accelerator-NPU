# MobileFaceNet Frontend RTL 開發筆記

## 目前狀態摘要

| Layer | 類型 | 狀態 |
|-------|------|------|
| Layer 0 | 3×3 Standard Conv | ✅ RTL 與 Fixed C-model **100.00% Exact Match** |
| Layer 1 | 3×3 Depthwise Conv | ✅ RTL 與 Fixed C-model **100.00% Exact Match** |
| Layer 2 | 1×1 Pointwise Conv | ✅ **效能優化版** (9-lane parallel) **100.00% Exact Match** |
| Layer 3 | Residual Shortcut  | ✅ **3-Buffer 輪轉** (Resid-Add) **100.00% Exact Match** |

> **Layer 0 ~ 3 總執行時間：7,730,700 cycles** (含 Pointwise 9x 加速)

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
| Layer 0 | 3×3 Standard Conv | 3×112×96 | 64×56×48 | ✅ 100.00% Exact Match |
| Layer 1 | 3×3 Depthwise Conv | 64×56×48 | 64×56×48 | ✅ 100.00% Exact Match |
| Layer 2 | 1×1 Pointwise Conv | 64×56×48 | 64×56×48 | ✅ 100.00% Exact Match (9-lane opt) |
| Layer 3 | Residual Addition  | 64×56×48 | 64×56×48 | ✅ 100.00% Exact Match (Resid-Add) |

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

---

## 15. 總結

MobileFaceNet Frontend RTL 已從單層 3×3 Conv 推進到前三個 convolution stages。

**最重要的成果：**

1. **Pointwise (1x1) 卷積優化**：透過 9 通道並行讀取，大幅提升計算效率。
2. **殘差連接 (Residual) 支援**：建立 3-buffer 管理機制，支援 `output = f(input) + shortcut`。
3. **時序與流水線優化**：MAC Array 具備 2-stage pipeline，有利於 100MHz+ 合成。
4. **驗證進度**：Layer 0, 1, 2, 3 全部達到 **100.00% Exact Match**。

**下一階段重點：**
- [ ] **全模型自動化測試**：修改 `gen_hex.py` 載入 MobileFaceNet 完整 50 層權重。
- [ ] **Synthesis 驗證**：在 moore server 上使用 Design Compiler 檢查實時時序 (Timing Closure)。
- [ ] **特殊層支援**：針對 `linear7` (7x6 kernel) 調整位址產生器邏輯。

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

## 20. 下一步工作 (Next Steps)

1. **全網路配置自動化**：開發指令碼從 PyTorch/ONNX 直接提取 50 餘層的權重與 Config，生成完整的 `config.hex` 與 `weights.hex`。
2. **多 Buffer 策略優化**：考慮加入更智慧的 Buffer 分配算法，以支援更高解析度或更深通道的 Feature Maps。
3. **前端系統整合**：目前僅在 TB 運作，需準備 AXI-Stream 接口與外部 DMA 接軌。


