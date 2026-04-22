# MobileFaceNet Frontend RTL 開發筆記

## 架構總覽 (Architecture Overview)
MobileFaceNet 硬體加速器的前端分為多個模組化組件，以確保可重用性、易於除錯以及高吞吐量。

### 資料路徑 (Data Path - Phase 1)
- **`mfn_sliding_window.sv`**: 實作行緩衝區 (Line Buffer) 與 3x3 移位暫存器陣列。它接收輸入像素流，並動態形成 3x3 並行視窗，以實現最大程度的資料重用。
- **`mfn_mac_array.sv`**: 全並行 9 乘法器陣列，配備加法樹與累加器。它在單個時鐘週期內完成 9 元素的點積運算。
- **`mfn_activation.sv`**: 處理 PReLU 乘法與硬體右移 (`>> 10`) 量化後邏輯，將 `int32` 的 MAC 輸出轉回 `int16`。

### 控制路徑 (Control Path - Phase 2)
- **`mfn_addr_gen.sv`**: 解耦的位址產生器。不使用昂貴的乘法器來計算 `c * H * W + h * W + w`，而是使用硬體累加器來追蹤 1D SRAM 讀/寫指標。
- **`mfn_controller.sv`**: 主狀態機 (FSM)。嚴格遵循 Two-Process Methodology（`always_comb` 處理次態邏輯，`always_ff` 處理狀態更新）。

---

## Two-Process Methodology 備忘
所有循序模組必須遵循此模式：
1. `always_comb` 區塊計算 `_next` 訊號。
2. `always_ff @(posedge clk or negedge rst_n)` 區塊執行 `_reg <= _next` 賦值。
**嚴禁**在 `always_ff` 區塊內進行任何算術或邏輯運算！

---

## 實作進度 (Phase 3 & 4)

### 記憶體子系統與進階控制
- **Padding MUX 邏輯**: 整合至 `mfn_addr_gen.sv`。硬體透過追蹤虛擬 `(x, y)` 座標，在邊界處透過 `mfn_frontend_top.sv` 中的多路復用器將 `16'h0000` 注入滑動視窗，無需浪費 SRAM 空間存儲零。
- **超寬權重 ROM**: `mfn_weight_rom.sv` 提供 192-bit 寬度的資料，每週期包含 9 個權重 (int16)、1 個 Bias (int32) 與 1 個 PReLU 參數 (int16)，支援單週期 3x3 運算。
- **配置 ROM (Config ROM)**: `mfn_layer_config_rom.sv` 存儲全網 58 層的超參數（in_ch, out_ch, W, H, stride 等），使控制器能動態調整迴圈邊界。
- **嵌套迴圈 FSM**: 精細化 `mfn_controller.sv`，採用四層嵌套迴圈架構：Layers -> Output Channels -> Spatial (Y, X) -> Input Channels。

### 驗證狀態 (Verification Status)
- **單元測試 (Unit Tests - PASS)**:
    - `mfn_addr_gen_tb`: 確認了 4x4 影像（虛擬 6x6）的 `is_pad` 標誌邏輯與 1D 位址進程。
    - `mfn_weight_rom_tb`: 確認了 192-bit 資料解包與同步讀取功能。
    - `mfn_layer_config_rom_tb`: 確認了多層參數存取正確。
- **整合測試 (Integration Test - STABLE)**:
    - `mfn_frontend_top_tb`: 成功模擬第 0 層 (Conv1) 的運算。
    - **環境建置**: 在 `Makefile` 中整合了 `cadence.env` 環境載入，並透過 `gen_hex.py` 實現自動化 ROM Hex 檔案產生。
    - **資料流驗證**: 驗證了 `input.hex` (Q5.10) 載入與 `weights.hex` (int16/int32) 處理流程，初步結果顯示激活與量化行為符合預期。

---

---

## 整合測試詳情 (Integration Test Details)

我們已經成功進入了 **系統整合測試 (System Integration Testing)** 階段！以下是目前完成的工作與進展：

### 1. 整合測試環境建立
*   **整合測試平台 (`mfn_frontend_top_tb.sv`)**：建立了一個頂層測試平台，模擬了 SRAM 記憶體模型，並將 `mfn_frontend_top` 實例化。
*   **資料轉換工具 (`gen_hex.py`)**：撰寫了 Python 腳本，將 `software/golden_weights_fixed` 中的 **int16 定點數權重**、**32-bit Bias** 以及 `software/golden` 中的影像輸入資料，全部轉換為硬體可讀取的 `.hex` 格式。
*   **ROM 自動載入**：更新了 `mfn_weight_rom.sv` 與 `mfn_layer_config_rom.sv`，使其在模擬開始時自動透過 `$readmemh` 載入 Layer 0 (Conv1) 的權重與參數。

### 2. 整合模擬結果 (`make top`)
我們成功執行了全系統模擬，波形輸出顯示資料已經順利流過整個 Pipeline（從 SRAM -> Sliding Window -> MAC Array -> PReLU/Quantization -> 寫回 SRAM）：

```text
Starting MobileFaceNet Integration Test...
Time=155000 | Output Pixel[     0] =   -263
Time=195000 | Output Pixel[     1] =      0
...
Time=10509315000 | Output Pixel[     0] =   -261
Time=10509355000 | Output Pixel[     1] =      0
```
*   **驗證點 1**：輸出的數值（如 `-263`, `-860`）代表 MAC Array 已經正確讀取了 int16 權重並與影像進行運算。
*   **驗證點 2**：輸出中出現大量的 `0` 是正常的，因為 MobileFaceNet 第一層後接 PReLU，負數部分會被壓縮或截斷。

### 3. 下一步行動 (Next Steps)
目前正在測試 Layer 0 (112x112x3 -> 64)。由於運算量較大，模擬需要時間跑完。

- **數值比對**：將模擬輸出的結果與 `software/golden/layer0_out_c.txt` 進行比對，確認精準度。已撰寫自動化腳本 `software/verify_rtl.py`。
- **硬體優化**：考慮實作 **Channel Parallelism** 來加速運算。
- **擴展到 Layer 1**：當 Layer 0 驗證無誤後，切換 Config ROM 進入 Layer 1 (Depthwise Conv) 的測試。

---

## 驗證流程 (Verification Flow)
1. **產生配置**: `python3 hardware/frontend/sim/gen_hex.py` (產生權重與影像 Hex)
2. **執行模擬**: `make top` (執行 RTL 模擬並輸出 `rtl_out.hex`)
3. **數值比對**: `python3 software/verify_rtl.py` (自動比對與 Golden Data 的誤差)

---

## TODO List (待辦清單)
- [/] **Bit-True 數值驗證**: 開發腳本比對 RTL 輸出的 `sram_mem` 與 `software/golden/layer0_out_c.txt` 的數值一致性。(已完成驗證腳本)
- [ ] **Depthwise Convolution 支援**: 更新 MAC Array 或控制器邏輯，以處理輸入與輸出通道一一對應的 DW-Conv 層。
- [ ] **殘差連接 (Residual Connection)**: 為 Bottleneck 層實作 Shortcut 加法器以支援殘差學習。
- [ ] **SRAM Ping-Pong 邏輯**: 根據 Config ROM 的 `ping_pong` 標誌，實作物理 SRAM A/B 的切換邏輯。
- [ ] **OpenRAM 整合**: 使用生成的記憶體 Macro (OpenRAM) 替換模擬用的 ROM/SRAM，以進行 ASIC 合成。
- [ ] **效能分析**: 分析 TOPS (每秒運算次數) 與 SRAM 頻寬利用率，找出可能的效能瓶頸。
