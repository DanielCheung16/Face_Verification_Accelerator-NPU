# MobileFaceNet Golden Reference C Model (v1.0) - 開發筆記

## 1. 架構與目的
這份專案旨在建立一個硬體友善、精確對齊（Bit-true）的 C 語言參考模型（C Reference Model），對應提案規劃中的 `Week 3-4` 目標。這會為接下來的 SystemVerilog RTL 開發提供一個穩固的黃金標準比對對象。

目前專案已從單層驗證（v0）升級為 **全網端到端推論 (End-to-End Inference)**，支援從圖片輸入到輸出 128D Embedding 的完整流程。

### 資料夾結構與用途 (Detailed)
位於 `software/` 目錄下的主要架構與其在開發流程中的角色：

1. **`software/golden/` (存放測試輸入與標準結果)**
   - **內容**：包含測試影像輸入 (`layer0_in.txt`) 以及每一層運算後的標準答案（Golden Output）。
   - **差異**：你會看到檔名結尾有不同後綴：
     - `_pytorch.txt`: PyTorch 浮點數結果（原始參考）。
     - `_c.txt`: C 語言模型浮點數結果。
     - **`_fixed.txt`**: 定點數（Fixed-point）模擬結果，這是硬體最精確的參考對象。
   - **誰在使用**：**`verify_rtl.py`**。它會讀取這裡的 `_fixed.txt` 檔案，拿來跟 RTL 跑出的 `.hex` 結果做位元級（Bit-true）比對。

2. **`software/golden_weights/` (原始浮點數權重)**
   - **內容**：包含所有層的原始浮點數權重、Bias 與 PReLU 參數。
   - **用途**：這是還沒經過量化（Quantization）的原始資料，通常提供給 C 語言浮點數模型或 PyTorch 腳本使用。

3. **`software/golden_weights_fixed/` (量化後的定點數權重)**
   - **內容**：包含已經量化成整數（例如 16-bit Q10 或 32-bit Q20）的權重與參數。
   - **差異**：這裡的數值是硬體（RTL）可以直接處理的整數格式。
   - **誰在使用**：**`gen_hex.py`**。它會讀取這裡的定點數權重，並把它們打包成硬體模擬所需的 `.hex` 檔案。

#### 總結對照表

| 資料夾 | 主要內容 | `verify_rtl.py` 用它嗎？ | `gen_hex.py` 用它嗎？ |
| :--- | :--- | :---: | :---: |
| **`golden/`** | 輸入資料與各層**標準結果** | **是** (讀取 `_fixed.txt` 比對) | 否 |
| **`golden_weights/`** | 原始**浮點數**權重 | 否 | 否 |
| **`golden_weights_fixed/`** | 量化後的**定點數**權重 | 否 | **是** (讀取權重轉成 `hex`) |

**快速指南：**
- 如果你要**產生給硬體跑的資料**，請找 `golden_weights_fixed`。
- 如果你要**檢查硬體跑得對不對**，請看 `golden` 目錄下的 `_fixed.txt` 結果。

---

## 2. 關鍵硬體友善設計 (Hardware-Friendly Design)

### Conv-BN Fusion (卷積與正規化融合)
*   **痛點**：PyTorch 中卷積後面會接 BatchNorm2d。如果硬體要實作 BatchNorm，將會消耗大量無謂的 DSP (乘法器) 與 BRAM/暫存器來存 Mean, Variance, Gamma, Beta。
*   **解法**：我們在 Python 導出階段執行了 **Conv-BN Fusion**。也就是透過數學推導，將 BatchNorm 的運算摺疊 (Fold) 進原本的 Conv Weight 跟 Bias 當中。
*   **結果**：C Model 與 RTL SystemVerilog 裡面**完全不需實作** `BatchNorm`，只需要實作一個純粹的 `y = W_fuse * x + B_fused` 即可。

### 記憶體與硬體對齊 (Ping-Pong Buffering & Layout)
- **NCHW 排列**：確保 C 記憶體指標操作與 PyTorch 原生排列一致，轉換為一維陣列儲存，便於 RTL 轉譯為 SRAM。
- **Ping-Pong Buffer**：在 `inference_main.c` 的全網推論迴圈中，利用兩個交替的 `Tensor3D` 緩衝區來節省記憶體，並搭配 Residual Shortcut 暫存區，精準模擬硬體的資料流動。

---

## 3. 核心工具與程式碼用法 (How to use)

### A. Python 端：權重導出與驗證工具
請先進入 `python/` 資料夾並啟用虛擬環境 (`source .venv/bin/activate`)：

1. **`python3 export_golden.py` (模組化單體驗證)**
   - 用途：針對 MobileFaceNet 裡的 4 種獨特結構（Standard Conv, Depthwise Conv, 展開的 Bottleneck, 帶 Residual 的 Bottleneck）進行獨立導出。
   - 配合：執行 C 端的 `./c_golden_model`，可確保你們寫的 RTL 在單一積木邏輯上是完全正確的（Max Error < 1e-4）。
   
2. **`python3 export_full_model.py` (全網權重導出)**
   - 用途：自動爬過 MobileFaceNet 的 50 幾層網路，並將每一層 Fusion 後的權重與偏差匯出到 `software/golden_weights/`。**（如無修改權重，只需執行一次）**。

3. **`python3 compare_similarity.py` (全網比對整合測試)**
   - 用途：這是最高層級的驗證。程式內建了 `PyTorchEngine` 和 `CModelEngine` 兩個 Class。它會吃進 `tfrecord` 裡的人臉圖片，同時呼叫 PyTorch 與編譯好的 C 程式 `./c_inference_model`，然後印出兩者的 Cosine Similarity 進行絕對精確比對。

4. **`python3 compare_rtl_cmodel.py` (RTL vs C 定點數模型比對)**
   - 位置：`software/compare_rtl_cmodel.py`
   - 用途：將 RTL 模擬輸出（`make top` → `rtl_out_layer49.hex`）與 C 定點數模型（`c_inference_model_fixed`）的 128D embedding 進行 bit-level 比對，並計算人臉對的 Cosine Similarity，驗證 RTL 硬體在真實人臉圖片上的推論正確性。
   - **與 `compare_similarity.py` 的差異**：前者比較 PyTorch vs C float model；本工具比較 **RTL simulation vs C fixed-point model**，是硬體最終正確性的端到端驗證。

   **快速使用：**

   ```bash
   # 只跑 C 定點數模型（快，秒級），適合多張圖片的相似度比較：
   python3 software/compare_rtl_cmodel.py \
     --images software/python/test_images/img_191.jpg \
                software/python/test_images/img_275.jpg \
                software/python/test_images/img_1018.jpg \
     --no-rtl

   # 同時跑 RTL 模擬（慢，每張 ~5 分鐘），驗證前 N 張圖的 RTL 輸出：
   python3 software/compare_rtl_cmodel.py \
     --images software/python/test_images/img_191.jpg \
                software/python/test_images/img_275.jpg \
     --rtl-count 1 --save-cache

   # 下次直接讀快取，不重新跑模擬：
   python3 software/compare_rtl_cmodel.py \
     --images software/python/test_images/img_191.jpg \
                software/python/test_images/img_275.jpg \
     --load-cache --no-rtl
   ```

   **輸出格式：**
   ```
   COSINE SIMILARITY MATRIX — C Fixed Model
   ─────────────────────────────────────────────
                  img_191.jpg   img_275.jpg
   img_191.jpg       1.0000        0.0179
   img_275.jpg       0.0179        1.0000

   RTL vs C MODEL — Embedding Exact Match
   ─────────────────────────────────────────────
   Image               Exact Match   Max Diff   Mean AbsErr
   img_191.jpg            128/128          0        0.0000
   ```

   **注意事項：**
   - C model 需從自己的目錄執行（script 已自動處理 `cwd`）
   - RTL 每次模擬會覆寫 `software/golden/layer0_in.txt` 與所有 hex 檔，若需保留原始 hex 請先備份
   - 快取檔案存在 `software/embedding_cache.json`，跨 session 有效

### B. C 語言端：純 C 參考模型
請進入 `c_model/` 資料夾並執行 `make` 進行編譯：

1. **`./c_golden_model`**
   - 源碼：`main.c`
   - 用途：**硬體單體測試 (Unit Test)**。執行 4 個獨立的 Layer 測試（Layer 0, 1, 2, 3），供 RTL 工程師對照波形 (Waveform) 除錯，檢查 MAC Array 與 Residual 加法。

2. **`./c_inference_model <input.txt> <output.txt>`**
   - 源碼：`inference_main.c`
   - 用途：**硬體端到端測試 (End-to-End Test)**。讀取一張正規化後的特徵圖 `input.txt`，並利用雙層迴圈解析所有 15 層 Bottleneck，最後將 128 維的特徵向量輸出至 `output.txt`。

---

## 4. 自動化精準比對結果 (Verification Validation)

在執行 `compare_similarity.py` 的雙軌測試後，我們得出了以下的驗證成果：

**同一個人 (Same Person) 相似度比對：**
- `[PyTorch] 0.8242`
- `[C Model] 0.8242`
- **差異：0.000001 (PASS)**

**不同人 (Different People) 相似度比對：**
- `[PyTorch] -0.0050`
- `[C Model] -0.0050`
- **差異：0.000008 (PASS)**

這證明了我們開發的 **純 C 語言推論引擎** 在長達 50 層的運算疊加後，數值依然與 PyTorch 原生運算保持完美的單精度浮點對齊。

---

## 5. 為什麼需要兩套 C 執行檔？ (RTL 驗證策略)

在硬體 (SystemVerilog/Verilog) 開發中，這兩個執行檔分別對應了不同的開發階段：

### 第一階段：單元模組開發 (Unit-Level) -> 使用 `c_golden_model`
剛開始寫 RTL 時，你會從最小的積木開始寫（例如 3x3 的 MAC Array 或 Line Buffer）。
*   **痛點**：這時候如果用全網推論去測，跑出一個 128D 的錯誤結果，你根本不知道是第一層寫錯、還是第七層寫錯。
*   **用法**：這時候你會依賴 `c_golden_model`。它只測試單一層（Layer 0 ~ 3），你只要看波形確保 RTL 模組算出的答案跟 `golden/layerX_out_c.txt` 一模一樣，硬體模組就過關了！

### 第二階段：系統整合 (Top-Level) -> 使用 `c_inference_model`
當你把所有的積木、記憶體控制器、以及主狀態機 (State Machine) 全部用 Verilog 組合起來，變成一個完整的「AI 加速器」時。
*   **痛點**：硬體現在是一個大黑箱，你必須證明晶片「真的能識別人臉」。
*   **用法**：這時候你會依賴 `c_inference_model`。你在 Verilog Testbench 餵給晶片一張圖，晶片幾萬個 Cycle 後吐出 128 維向量。只要這 128 個數字與 `c_inference_model` 算出來的 `128d_output.txt` 完全吻合，你的整顆晶片設計就大功告成！

總結來說，`c_golden_model` 是除錯工具（抓模組 Bug），而 `c_inference_model` 是期末考卷（證明晶片能運作）。

---

## 6. 後續建議 (Next Step for SystemVerilog RTL)

1. **模組開發**：硬體工程師現在可以直接看著 `conv.c` 的迴圈寫出 `MAC Array`，並看著 `tensor.c` 的 `add_tensor_inplace` 寫出 `Residual Adder`。
2. **定點數轉換 (Quantization)**：目前版本依然使用 Float32 運算以對齊數學演算法。當硬體開始引入 `INT8 / INT16` Quantization (量化) 時，只需修改 `tensor.c` 裡的資料型別，並修改 Python 端的導出位移量，即可輕鬆驗證 Quantization 造成的精準度耗損。

---

## 7. 硬體記憶體架構 (SRAM & OpenRAM 指南)

在進行 RTL 實作時，**絕對會需要使用 SRAM** 來儲存大量的特徵圖 (Feature Maps) 與權重 (Weights)，不能僅依靠 Flip-Flops (DFF)。例如一層 `64 x 56 x 48` 的特徵圖若使用 16-bit 儲存，約需 344 KB 空間，若硬用 DFF 合成會導致面積爆炸且無法繞線。

### 沒有 CPU 的情況下如何控制 SRAM？
在 ASIC 設計中，我們不需要 CPU。我們會在 SystemVerilog 中設計一個 **Memory Controller + FSM (狀態機)** 來操控 SRAM：
1. **FSM (大腦)**：負責掌控當前在算哪一層的第幾個 Pixel。
2. **Address Generator**：依據迴圈公式（例：`addr = c * (H * W) + y * W + x`）算出記憶體位址。
3. **讀寫控制**：把算出的 `addr` 送給 SRAM 的位址接腳，並透過切換 `we_n` (Write Enable) 來控制要讀取輸入資料，還是將 MAC 算完的結果寫回 SRAM。
這就是我們在 C Model 裡實作 **Ping-Pong Buffer** 的硬體對應作法：兩塊 SRAM 交替做為 Input 與 Output。

### OpenRAM 產生 SRAM 巨集教學 (FreePDK45)
為了取得能在硬體合成 (Genus/Innovus) 使用的 SRAM `.v`, `.lib`, `.lef` 檔案，請依循以下教學使用 OpenRAM 生成 SRAM Macros：

```bash
# 1. 建立一個新的資料夾來產生 RAM 檔案，並進入該資料夾
mkdir sram_generation && cd sram_generation

# 2. 複製 OpenRAM 腳本與設定檔範本
cp /vol/ece393/tools/OpenRAM/sram_compiler.py .
cp /vol/ece393/tools/OpenRAM/macros/sram_configs/freepdk45_sram_1rw1r_32x2048_8.py .

# 3. 根據你的硬體需求 (Word Size, 深度等) 修改 freepdk45_sram_1rw1r_32x2048_8.py 裡的參數
# vi freepdk45_sram_1rw1r_32x2048_8.py

# 4. 安裝 OpenRAM (若尚未安裝)
pip3.8 install openram --user

# 5. 執行編譯器生成 SRAM
python3.8 sram_compiler.py freepdk45_sram_1rw1r_32x2048_8.py
```
> [!NOTE]
> 執行通常需要 5~10 分鐘。完成後，所有生成的 SRAM 檔案（含 Verilog wrapper 與 Lib）都會在 `macro` 資料夾中。你可以將產生的 `.v` 當作普通的 module instantiate 到你的 SystemVerilog 頂層設計中。

---

## 8. 端到端相似度驗證工具 (Eval & Similarity Pipeline)

### 8.1 目錄結構重整

所有驗證與比較工具已整合到 `software/eval/`，圖片資料集移到 `software/src/`：

```
software/
├── eval/                          # 驗證 / 比較工具
│   ├── verify_rtl.py              # 單層 RTL vs C Golden 精確比對
│   ├── run_verify.py              # 全流程：圖片→ golden → RTL → 所有層比對
│   ├── eval_my_photos.py          # 個人照片 cosine similarity matrix
│   ├── eval_rtl_similarity.py     # 全圖片資料夾：C model + RTL similarity matrix
│   ├── compare_rtl_cmodel.py      # 直接指定圖片，比對 RTL vs C embedding
│   └── compare_similarity.py      # 多引擎比對 (PyTorch/C/C_fixed，Mac only)
├── src/                           # 圖片資料集
│   ├── test_image_my_new/         # 個人照片（新版）
│   ├── test_image_my_ori/         # 個人照片（原版）
│   ├── test_images/               # TFRecord 擷取的測試圖
│   └── dataset_samples/           # 標籤資料集樣本
└── python/                        # model / training / export 工具
```

> 從 project root 跑，不需要進 `software/python/`。

### 8.2 常用指令

```bash
# 1. 只跑 C model，看個人照片 similarity matrix（最快）
python3 software/eval/eval_my_photos.py --dir software/src/test_image_my_new

# 2. C model + RTL，同時跑完整 similarity matrix（~5 min/image）
python3 software/eval/eval_rtl_similarity.py --dir software/src/test_image_my_new

# 3. C model only（跳過 RTL）
python3 software/eval/eval_rtl_similarity.py --dir software/src/test_image_my_new --no-rtl

# 4. 用 cache 不重跑（cache 存在 software/embedding_cache.json）
python3 software/eval/eval_rtl_similarity.py --dir software/src/test_image_my_new --load-cache

# 5. 完整驗證：同一張圖跑 golden + RTL，比對所有 50 層
python3 software/eval/run_verify.py --image software/src/test_image_my_new/elon_1.jpg

# 6. 只比對現有檔案（不重跑任何東西）
python3 software/eval/run_verify.py --verify-only

# 7. 比對單層（L0）
python3 software/eval/verify_rtl.py 0
```

### 8.3 verify 工具的重要前提

`verify_rtl.py` 和 `run_verify.py` 比對的兩份資料必須來自**同一張圖**：

| 來源 | 路徑 | 產生方式 |
|---|---|---|
| C model golden | `software/golden/layer*_out_fixed.txt` | `python3 software/gen_all_golden.py` |
| RTL 輸出快照 | `hardware/frontend/sim/layer_hex/rtl_out_layer*.hex` | `make top` (in sim/) |

兩者都從 `software/golden/layer0_in.txt`（float pixel 值）出發。  
用 `run_verify.py --image` 會自動把兩邊都跑，保證輸入一致。

### 8.4 Testbench 輸出路徑

`mfn_frontend_top_tb.sv` 的 `$writememh` 分兩類：

| 輸出 | 路徑 | 用途 |
|---|---|---|
| 每層 SRAM 快照 | `layer_hex/rtl_out_layer{N}.hex` | `verify_rtl.py` 逐層比對 |
| 最終完整 SRAM | `hex/rtl_out.hex` | `eval_rtl_similarity.py` 取 L49 embedding |

`hex/input.hex` 和 `hex/rtl_out.hex` 都是 generated，已加入 `.gitignore`。

### 8.5 Git 追蹤策略（Generated Files）

以下為 generated 檔案，已從 git tracking 移除（`git rm --cached`）並加入 `.gitignore`：

- `software/golden/layer*_out_fixed.txt`（換圖就變）
- `software/golden/layer0_in.txt`（test input）
- `hardware/frontend/sim/hex/input.hex`
- `hardware/frontend/sim/hex/rtl_out.hex`
- `hardware/frontend/sim/layer_hex/`（已在 gitignore）
- `software/embedding_cache.json`

仍需 commit 的 golden 檔：`layer*_weight.txt`、`layer*_bias.txt`、`layer*_prelu.txt`（model weights，固定不變）。
