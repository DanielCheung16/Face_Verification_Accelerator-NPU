# MobileFaceNet Golden Reference C Model (v1.0) - 開發筆記

## 1. 架構與目的
這份專案旨在建立一個硬體友善、精確對齊（Bit-true）的 C 語言參考模型（C Reference Model），對應提案規劃中的 `Week 3-4` 目標。這會為接下來的 SystemVerilog RTL 開發提供一個穩固的黃金標準比對對象。

目前專案已從單層驗證（v0）升級為 **全網端到端推論 (End-to-End Inference)**，支援從圖片輸入到輸出 128D Embedding 的完整流程。

### 資料夾結構
位於 `software/` 目錄下的架構：
- `python/`：包含 MobileFaceNet 的 PyTorch 推論腳本、模型權重匯出工具、以及 C/Python 雙軌比對驗證程式。
- `c_model/`：C Reference Model 實作原始碼，包含積木驗證模組與全網推論引擎。
- `golden/`：存放用於 **Block-by-Block (單一模組)** 驗證的中繼純文字檔案 (Weights, Biases, Activation I/O)。
- `golden_weights/`：存放 **全網推論 (End-to-End)** 所需的 150+ 個已融合 (Fused) 參數檔案。

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
