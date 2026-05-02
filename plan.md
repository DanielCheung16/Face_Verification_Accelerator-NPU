# CE492 Face Verification Accelerator - Detailed Execution Plan

## 0. 文件目的
這份文件把 proposal 轉成可直接執行的工程計畫，核心原則是：
先把 C 參考模型做對、做穩，再推 RTL 與 FPGA 原型。

適用範圍：
1. Configurable sliding-window CNN accelerator
2. 目標 workload 以 MobileFaceNet 風格卷積層為主
3. 評估指標：TOPS、throughput、power、area

---

## 1. 現在應該做什麼（結論先行）
目前最優先不是先寫完整 RTL，而是先完成三件事：
1. 定義可重現的 C reference model（輸入/輸出格式固定、參數固定、可一鍵重跑）
2. 先做最小可驗證卷積子系統（line buffer + sliding window + PE/MAC）
3. 建立 golden-driven verification flow（每個 RTL 模組都能對 C golden）

換句話說，工作順序是：
C baseline -> Golden vectors -> Module RTL -> Module compare -> Integration。

---

## 2. 與 proposal 對齊的技術主線
proposal 已明確指出：
1. 設計要「可配置」而非 hard-code 固定網路
2. 架構核心是 sliding-window data reuse
3. 驗證方法是 software golden model 對 RTL
4. 後續在 FPGA 收集效能與資源數據

所以實作上必須先把下面三個 contract 凍結：
1. Layer config word 格式
2. 數值格式（int8/int16/fixed-point 寬度、累加寬度、飽和/截斷規則）
3. 每層 I/O tensor 排列與記憶體 layout（NCHW 或 NHWC）

若這三項未先定義，後面 controller、buffer、PE 全都會反覆重工。

---

## 3. C Reference Model 詳細規劃（第一優先）

## 3.1 目標
建立一個「硬體友善」C 參考模型，不求完整訓練流程，只求推論路徑與數值行為可驗證。

## 3.2 建議功能切分
C model 建議最少包含以下模組：
1. Tensor/feature map 資料結構
2. conv2d（支援 stride、padding、kernel size）
3. depthwise conv2d（MobileFaceNet 關鍵）
4. pointwise 1x1 conv
5. activation（ReLU 或 ReLU6）
6. optional pooling
7. layer runner（根據 config word 執行 layer sequence）
8. dump utility（輸出每層中間結果與最終結果）

## 3.3 Golden 輸出規格（先定義再寫 RTL）
每層至少輸出：
1. layer_id
2. input tensor checksum
3. output tensor checksum
4. output full dump（debug 模式）
5. output compact dump（regression 模式）

檔案格式建議：
1. 純文字十進位（易 debug）
2. 每行一個元素或固定 row-major 區塊
3. 檔頭寫明 shape、dtype、scale、zero-point（若用量化）

## 3.4 C model 驗收標準
1. 同一組輸入重跑三次，輸出完全一致
2. 單層測試可獨立執行（不是只能跑整網路）
3. 可開關 debug dump（full / compact）
4. 可用 config 檔指定層參數，不必改程式重編

---

## 4. RTL 實作順序（不要一開始就做整機）

## 4.1 模組優先序
1. line buffer + sliding-window generator
2. PE/MAC array（先做單一 kernel，再擴展平行度）
3. accumulator / psum path
4. activation block
5. controller/scheduler（解碼 config）
6. input/output buffer + memory interface

## 4.2 每個模組共同驗證模板
每個模組都要有：
1. 單元 testbench
2. C 對照輸入向量
3. pass/fail summary（checked/mismatch）
4. 首個 mismatch 定位資訊（index + expected + got）

## 4.3 第一個 RTL milestone
最小可運作路徑：
line buffer -> window -> MAC -> psum -> activation

只跑一層 3x3 conv（固定參數），先完成 bit-true 或明確容差對齊。

---

## 5. Controller 與 Configurable Flow 設計

## 5.1 Layer Config Word 最小欄位
第一版先包含：
1. op_type（conv/depthwise/pointwise/act）
2. H, W, Cin, Cout
3. K, stride, padding
4. activation_type
5. input_addr, weight_addr, output_addr

## 5.2 版本策略
1. v0：只支援 conv + ReLU
2. v1：加入 depthwise + pointwise
3. v2：支援 MobileFaceNet 簡化 layer sequence

每次升版都要先擴 C model，再擴 RTL，最後回歸測試。

---

## 6. FPGA 原型與量測規劃

## 6.1 要收集的數據
1. Fmax
2. 吞吐量（images/s 或 layers/s）
3. 資源使用（LUT/FF/BRAM/DSP）
4. 功耗（工具估計）

## 6.2 量測條件固定
1. 固定 clock constraint
2. 固定測試 layer set
3. 固定 batch/input size
4. 固定量化參數

否則不同版本的 throughput/power/area 不能公平比較。

---

## 7. 10 週可執行排程（依 proposal 節奏細化）

## Week 1-2: Background + Spec Freeze
1. 凍結數值格式與 tensor layout
2. 凍結 layer config word v0
3. 建立 C model 專案骨架

Exit criteria:
1. 有 spec 文件
2. 有可編譯 C 專案

## Week 3-4: C Reference Model Complete (v0)
1. 完成 conv/activation/layer runner
2. 產生第一版 golden vectors
3. 建立 checksum + full dump 機制

Exit criteria:
1. C model 可一鍵重跑
2. 產出 deterministic golden

## Week 5-6: Core RTL Bring-up
1. line buffer + sliding-window RTL
2. PE/MAC + psum RTL
3. 單層卷積對 C golden

Exit criteria:
1. 單層路徑比對通過

## Week 7: Controller v0 Integration
1. controller 解碼 config
2. 串接 input/weight/output buffer
3. 跑多層簡化序列

Exit criteria:
1. 多層序列與 C model 對齊

## Week 8: Extend to Depthwise/Pointwise
1. C model 與 RTL 同步擴展
2. 驗證 MobileFaceNet 風格 block

Exit criteria:
1. 代表性 block 全通過

## Week 9: FPGA Prototype + Metrics
1. 上板或 FPGA flow
2. 收 Fmax/throughput/resource/power

Exit criteria:
1. 量測表可重現

## Week 10: Regression + Report Packaging
1. 整體 regression
2. 整理圖表與對照結果
3. 匯總限制與未來工作（例如 EdgeFace）

Exit criteria:
1. 報告可交付
2. 全流程可重跑

---

## 8. 分工建議（兩人版本）
Peixin:
1. C model 主責（layer runner、golden dump、config parser）
2. verification scripts（compare/checksum/regression）

Willie:
1. RTL 主責（line buffer、PE/MAC、controller）
2. FPGA flow（synth/P&R、timing、resource、power）

共同項目：
1. 每晚同步一次 golden 對照結果
2. 每週固定一次 spec 變更審查（避免 config 漂移）

---

## 9. 風險清單與對策
1. 風險：數值規格未凍結導致 RTL/C 長期 mismatch
   - 對策：第一週完成 numeric contract，之後改動必須寫變更紀錄
2. 風險：一次整合太多模組，難定位錯誤
   - 對策：嚴格單模組驗證，禁止未驗證模組直接進 top
3. 風險：Controller 提早複雜化
   - 對策：先做 v0 最小欄位，再逐版擴展
4. 風險：FPGA 指標不可重現
   - 對策：固定約束與測資版本，量測腳本化

---

## 10. 這週就要完成的 TODO（可直接執行）
1. 建立 `c_model/` 目錄與基本檔案：
   - `main.c`
   - `layer_runner.c/h`
   - `conv.c/h`
   - `tensor.c/h`
   - `io_dump.c/h`
2. 建立 `configs/` 並放 `model_v0.json`（或 txt）
3. 建立 `golden/` 輸出目錄
4. 寫第一個 end-to-end 命令：
   - 讀 config -> 跑 1 層 conv -> 輸出 `golden/layer0_out.txt`
5. 在 `rtl/sim` 寫第一個 compare testbench，對 `layer0_out.txt`

本週驗收標準：
1. 至少 1 層 conv 的 C 與 RTL 對照通過
2. 指令可由任一成員在乾淨環境重跑

---

## 11. 文件與證據管理
每次 milestone 至少留下：
1. 命令列紀錄（build/sim/synth）
2. 比對結果摘要（pass/mismatch）
3. 版本號（git commit）
4. 問題與修正紀錄（issue log）

建議新增文件：
1. `SPEC_numeric_contract.md`
2. `SPEC_config_word.md`
3. `VERIF_regression_checklist.md`
4. `FPGA_metrics_log.md`

---

## 12. 下一步（一句話）
先把 C reference model v0 做成可一鍵產生 golden 的流程，並用單層 3x3 conv 完成第一次 C-vs-RTL 對照，這是後續所有進度的地基。
