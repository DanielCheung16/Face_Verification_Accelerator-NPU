# Innovus P&R Notes — mfn_frontend_top

## 環境
- Tool: Cadence Innovus 16.20-p002_1
- PDK: NangateOpenCellLibrary / FreePDK45 (45 nm)
- MMMC: 單一 corner（tt, 1.1V, 25°C）
- Target clock：v1 = 100 MHz；v2 / v3 = 125 MHz（8 ns）

---

## 總覽：v1 → v2 → v3

| | v1 | v2 | v3（FF act_buf 版，P&R 完成） |
|--|----|----|------|
| 計算單元 | **單一 9-MAC 點積**（`mfn_mac_array`，9 乘法器，算 1 個 output ch 的 3×3）、ripple-carry 加法器、flat netlist | **雙 9-MAC**（2×`mfn_mac_array`，18 乘法器，並行算 2 個 output ch）、40-bit CLA、OpenRAM psum SRAM macro | **12×12 = 144-MAC 陣列**（`mfn_sa_12x12`，output-stationary）、act_buf、12-ch 寬載入；opt①②③④ |
| Cycles / inference | 43,158,478 | 25,768,847 | **12,281,668**（v3++ opt①②③④） |
| 合成 cell 數 / 面積 | — | 137,976 / 479k µm² | 268,231 / 455k µm² |
| P&R 狀態 | ✅ 完成 | ✅ 完成（DRC 0、timing met） | ✅ 完成（DRC 0、timing met，見下節） |
| DRC / Conn / Antenna | 0 / 0 / 0 ✅ | 0 / 0 / 0 ✅ | 0 / 0 / 0 ✅ |
| Timing | WNS +3.611 ns @100 MHz | setup +0.908 / hold +0.507 ns @125 MHz | setup +0.861 / hold +2.111 ns **@83 MHz**（critical ~11 ns） |
| 功耗 | 26.66 mW | 11.35 mW | 85.45 mW |
| FPS | ~2.3 fps @100 MHz | **4.85 fps @125 MHz** | **6.76 fps @83 MHz**（max ~90 MHz） |

（各版 RTL cycle 數的來源見 `frontend/note.md` §31–32。）

### 為什麼從 v2 換到 v3

> **澄清**：v1 / v2 **不是 systolic array**。它們是 MAC 點積單元 ——
> v1 = 單一 9-MAC（算 3×3 conv 的 9 個 tap），v2 = 雙 9-MAC（並行 2 個 output
> channel）。只有 v3 才是 12×12 = 144-MAC 的陣列架構。舊版 note 誤標為
> 「4×1 / 6×1 SA」，已更正。

v2 後端收斂得很乾淨（DRC 0、setup/hold 都正），但 **~5 fps 已是雙-MAC 架構的天花板**：

- v2 一個 cycle 只算 2 個 output channel（18 個乘法器）→ compute 平行度太低，
  cycle 數（25.8M）壓不下去。
- critical path（`SRAM → CLA-40 → SRAM`）已是優化過的 CLA，靠後端提頻最多再到 ~5.8 fps。
- 要再快只能從**架構**下手 → v3 用 **144-MAC 陣列（是 v2 18 個乘法器的 8 倍）**。

v3 再疊四項控制器優化 —— ① DW 12-ch 並行、② ACT_LOAD 與 WRITEBACK 重疊、
③ BIAS_LOAD 併入 WRITEBACK、④ 12-channel 寬載入 —— cycle 數降到 **12.28M
（v2 的 0.48 倍）**，同頻率下 FPS 約翻倍到 ~10 fps，且 50 層輸出與 v2 完全 MATCH。
v3 的 critical path 與 v2 相同（同一條 SRAM→CLA 路徑），後端可沿用同一套
P&R 流程（`run_innovus_3.tcl`，SRAM LEF 已修）。

---

## v1 結果 (`run_innovus.tcl`) — 2026-05-11

### 時序
| 指標 | 數值 |
|------|------|
| WNS post-layout | **+3.611 ns** ✅ |
| 最大可達頻率 | **~156 MHz** |
| Critical path start | `u_ctrl/c_out_d2_reg[0]/Q` |
| Critical path end | `u_ctrl/psum_mem_reg[181][38]/D` |
| 路徑內容 | 38-stage FA_X1 ripple carry (`add_507_58_g981` → `g943`)，~2.8 ns |

### 功耗 (default activity = 0.2)
| 項目 | 數值 |
|------|------|
| 總功耗 | 26.66 mW |
| Sequential | 15.93 mW (59.8%) — psum_mem 512×40 FF 主導 |
| Clock network | 4.43 mW (16.6%) |
| Combinational | 6.30 mW (23.6%) |

### 驗證
| 項目 | 結果 |
|------|------|
| DRC | **No violations** ✅ |
| Connectivity | **No problems or warnings** ✅ |
| Antenna | **No violations** ✅ |

### v1 特徵（vs v2）
- CTS：基本 `set_ccopt_property buffer_cells {CLKBUF_X1/X2/X3}`，無 NDR
- filler 在 routing 後插入
- 無 `timeDesign` 中間快照

---

## v2 結果 (`run_innovus_2.tcl`) — 2026-05-11（v2 RTL：run 1）

### v2 新增項目
1. **CTS NDR**：
   - `CTS_2W1S`（leaf, M1-M4）：雙倍線寬 / 單倍間距 → 降低 leaf 端 RC，減少 skew
   - `CTS_2W2S`（trunk, M7-M10）：雙倍線寬 / 雙倍間距 + VSS shield → 低 RC trunk + EMI 隔離
2. **`timeDesign` before each `optDesign`**：post-CTS 和 post-route 各加一次 timing snapshot
3. **`addFiller` before routing**：FILLCELL_X32→X1，保持 N-well continuity 與 M1 rail bridging

### 時序（run 1：v1 netlist + v2 tcl）
| 指標 | 數值 |
|------|------|
| WNS post-layout | **+3.710 ns** ✅ |
| 最大可達頻率 | **~159 MHz** |
| Critical path start | `u_ctrl/c_out_d2_reg[1]/Q` |
| Critical path end | `u_ctrl/psum_mem_reg[191][39]/D` |
| 路徑內容 | 38-stage FA_X1 ripple carry（**與 v1 相同**），~2.85 ns |

> ⚠️ Critical path 無改善：v2 P&R 仍使用 v1 Genus netlist（ripple carry）。
> CLA 效果需重新合成 `synthesis_v2.tcl` 才能看到。

### 功耗（run 1，default activity = 0.2）
| 項目 | 數值 | vs v1 |
|------|------|-------|
| 總功耗 | **26.24 mW** | −0.42 mW |
| Sequential | 15.79 mW (60.2%) | −0.14 mW |
| Clock network | **4.154 mW (15.8%)** | **−0.28 mW** ← NDR 效果 |
| Combinational | 6.298 mW (24.0%) | ≈ 持平 |

### 驗證（run 1）
| 項目 | 結果 |
|------|------|
| DRC | **No violations** ✅ |
| Connectivity | **No problems or warnings** ✅ |
| Antenna | **No violations** ✅ |

---

## v2 RTL P&R 結果 (`run_innovus_2.tcl` + `synthesis_v2.tcl`) — 2026-05-12（run 2）

使用正確的 v2 synthesis netlist（CLA + hierarchy 保留）。

### v2 RTL 合成結果
| 指標 | 數值 | vs v1 |
|------|------|-------|
| Total cells | 137,976 | +68,667（CLA + dual-MAC + FF array） |
| Total area | 479,455 µm² | +194,000 µm² |
| Synthesis WNS | **+5,897 ps** ✅ | 改善（原 ripple carry 消失） |
| Synthesis critical path | addr_gen output 2,003 ps | 新 critical（CLA 消除了 psum carry chain） |

### 時序（run 2，P&R 後，100 MHz target）
| 指標 | 數值 |
|------|------|
| WNS post-layout | **−0.922 ns** ❌ VIOLATED |
| Critical path | `c_out_d2_reg[2]` → psum_mem decode → `u_cla_b` → `psum_mem_reg[467][38]` |
| 路徑長度 | 11.461 ns (required 10.539 ns) |
| 問題根因 | 512-to-1 psum_mem decode + CLA + 16+ 個 routing buffer（因 congestion 插入） |

### 功耗（run 2，default activity = 0.2）
| 項目 | 數值 |
|------|------|
| 總功耗 | **57.46 mW** |
| Sequential (FF) | 18.39 mW (32%) |
| Combinational | 34.39 mW (60%) |
| Clock (NDR CTS) | 4.69 mW (8.1%) |

> 功耗比 v1 大是因為 cell count 2× 多（CLA adder + dual-MAC array + 512×40 psum FF）。

### 驗證（run 2）
| 項目 | 結果 |
|------|------|
| DRC | **1,000 violations** ❌（832 SHORT, 115 CUTSPACING, 53 SPACING） |
| Connectivity | **No problems** ✅ |
| Antenna | **No violations** ✅ |

### DRC 根本原因
全部集中在 u_ctrl 模組（psum_mem + CLA 區域）：
- floorplan utilization 50%，但 u_ctrl 有 125,720 cells（全設計 91%）
- Router 空間不足 → metal2/3 short，via 間距違反
- 與 timing violation 同一根因：設計太大、floorplan 太小

### 修復計劃（run 3 待執行）
1. **Floorplan 放大**：`floorPlan -r 1.0 0.35 5 5 5 5`（35% utilization → router 多 43% 空間）→ 已套用至 `run_innovus_2.tcl`
2. **降低 clock target**：100 MHz → 83 MHz（12 ns period）→ 已建立 `constraints_v2.sdc` + `mfn_frontend_top_v2.view`
3. 預期：DRC 大幅減少或清零，timing WNS 轉正

---

## 關鍵路徑說明

post-layout critical path 與合成時完全相同：**38-stage FA_X1 ripple carry**

這條 carry chain 在 RTL `mfn_controller.sv` 對應：
```sv
psum_mem[c_out_d2] <= psum_mem[c_out_d2] + mac_data_in;
```
Genus 在 5751 ps 大 slack 下選了 area-optimal FA_X1，Innovus 沒有理由重新優化。

→ **v2 RTL (`sv/v2/mfn_cla40.sv`)** 以 40-bit 2-level CLA 替換，需重新合成才能看到效果。

---

## 如何重新跑

```bash
# v1 合成（ripple carry，flat netlist）
cd hardware/frontend/syn
tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && genus -files synthesis.tcl"

# v2 合成（含 CLA，保留 hierarchy）
tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && genus -files synthesis_v2.tcl"
# 輸出：mfn_frontend_top_v2_syn.v  timing_v2.rep  area_v2.rep

# PG netlist（合成後需執行）
cd hardware/backend
make pg   # 將 v2_syn.v 加入 VDD/VSS port → mfn_frontend_top_syn_pg.v

# v1 P&R
make pnr

# v2 P&R（NDR + timeDesign + filler-first）
tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && innovus -files run_innovus_2.tcl"

# 開 Innovus GUI 看 v2 layout
tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && innovus"
# 在 Innovus console 輸入：
# restoreDesign mfn_frontend_top_v2_final.enc mfn_frontend_top
```

## 輸出檔案對照

| 檔案 | v1 | v2 |
|------|----|----|
| 設計資料庫 | `mfn_frontend_top_final.enc` | `mfn_frontend_top_v2_final.enc` |
| Netlist | `mfn_frontend_top_final_nophy.v` | `mfn_frontend_top_v2_final_nophy.v` |
| Timing report | `pnr_timing.rep` | `pnr_v2_timing.rep` |
| Power report | `pnr_power.rep` | `pnr_v2_power.rep` |
| DRC | `mfn_frontend_top.drc.rpt` | `mfn_frontend_top_v2.drc.rpt` |

---

## v2 DRC 根因修復 — SRAM LEF OBS 移除（2026-05-17）

### 背景：addFiller 重排已修好 IMPOPT-310
`addFiller` 從「routing 前」移到「post-route optimization 之後」，
解決了 `IMPOPT-310 Design density (100%)` 錯誤（filler 把 site 填滿 →
hold optimizer 無空間插 buffer）。重跑後此錯誤不再出現。

### 01:10 那次跑其實幾乎成功
`innovus.log` 顯示腳本一路執行到 `verify_drc` / `verifyConnectivity` /
`saveDesign` / `saveNetlist` 全部完成，只在最後一行裝飾用 `puts` banner 崩潰：
```
**ERROR: (IMPSYT-6693): invalid command name "32..39".
```
原因：`puts "...dout0[32..39]"` 在 TCL 雙引號內，`[32..39]` 被當成命令替換
去執行 `32..39`。**這是 TCL 語法 bug，不是 P&R 問題**。已修正 banner 文字。

### DRC 違規分析（該次 484 個）
| 區域 | 數量 | layer 分布 |
|------|------|-----------|
| SRAM_A (y 10–255) | 243 | M3:108  M4:135 |
| SRAM_B (y 280–490) | 240 | M3:86  M4:87  M5:67 |

### 根本原因
兩個合成 OpenRAM LEF（`sram_psum_a` / `sram_psum_b`）都帶有
**整塊 macro 的 M3 + M4 OBS**。dout pin 位於 M3，被 M3 OBS 上下夾住、
M4 又整塊封死 → **沒有任何合法的 via3 / M4 逃線路徑**。NanoRoute 在
congestion 下被迫穿過 OBS → ~480 個 SHORT / SPACING 違規。

之前的對策（加 hard `createRouteBlk`、在 OBS 挖小缺口）都是在跟 router
硬碰硬：缺口走廊只有 0.28 µm，8 條 `psum_rd_b[32..39]` 塞不下，被逼上 M5
→ 改成 M5 撞 VSS power stripe。治標不治本。

### 修復：移除合成 LEF 的 M3/M4 OBS
合成 SRAM 是**行為模型**，沒有真實的 M3/M4 內部繞線 — 那些 OBS 只是
過度保守的佔位。`fix_sram_lef.py` 對兩個 LEF：移除 M3/M4 OBS、保留
M1/M2 OBS、pin 完全不動 → 產生 `*_fixed.lef`。

router 因此能在 M3 dout pin 上打 via3、正常在 M4 繞線過 macro，
不再需要任何 `createRouteBlk`。

### 修改清單
| 檔案 | 變更 |
|------|------|
| `fix_sram_lef.py`（新） | 移除兩個 SRAM LEF 的 M3/M4 OBS → `_fixed.lef` |
| `sram_lef/sram_psum_a/b..._fixed.lef`（新） | 只剩 M1/M2 OBS；80 / 40 個 dout pin 完整保留 |
| `run_innovus_2.tcl` | 兩個 SRAM 改用 `_fixed.lef`；移除全部 M4 `createRouteBlk`；修掉 `puts` bug |
| `run_innovus_3.tcl` | 同上 |

### 重跑指令
```bash
cd hardware/backend
python3 fix_sram_lef.py      # 產生 _fixed.lef（已產生，僅需重跑可重產）
make pnr_v2
```
預期：M4 SHORT / M3 SPACING / M5-VSS SHORT 應全部消失。

---

## v2 P&R 最終結果（LEF 修復後，2026-05-17 13:50）

`run_innovus_2.tcl` + 修補後的 `_fixed.lef` 重跑（`innovus.log1`）。

### 驗證 — 全部乾淨 ✅
| 項目 | 結果 |
|------|------|
| **DRC** | **No DRC violations were found**（0）✅ |
| Connectivity | Found no problems or warnings ✅ |
| Antenna | No Violations Found ✅ |

→ 移除合成 LEF 的 M3/M4 OBS 完全解決了 ~480 個 SRAM-pin DRC，
且 IMPOPT-310、`puts` 語法 bug 都不再出現。

### 時序（target 8 ns / 125 MHz）
| 模式 | WNS | TNS | 結果 |
|------|-----|-----|------|
| Setup | **+0.908 ns** | 0.000 | MET ✅ |
| Hold  | **+0.507 ns** | 0.000 | MET ✅ |

關鍵路徑：`sram_a/dout0 → CLA-40 進位鏈 → sram_a/din0`（與 v2 合成一致）。
critical path = 8 − 0.908 = **7.092 ns → 實際最高 ~141 MHz**。

### 功耗（default activity）
| 類別 | Power (mW) | 佔比 |
|------|-----------|------|
| Macro（psum SRAM）| 3.55 | 31% |
| Combinational | 6.07 | 53% |
| Sequential | 1.36 | 12% |
| Clock | 0.38 | 3% |
| **Total** | **11.35 mW** | 100% |

Placement density 21.47%（560×500 µm core，floorplan 寬鬆）。

### FPS（v2 RTL：6×1 SA，25,768,847 cycles/inference）
| 頻率 | FPS | latency |
|------|-----|---------|
| 125 MHz（P&R target） | **4.85 fps** | 206 ms |
| 141 MHz（WNS 上限）   | **5.47 fps** | 183 ms |

### 需要修正的？
**沒有。** DRC / connectivity / antenna 全 0，setup + hold 都正，
功耗合理。v2 後端流程已完整收斂、可交付。

---

## v3 P&R 結果（FF act_buf 版，`run_innovus_3.tcl`，2026-05-18）

`innovus.log4` —— v3（12×12 SA，opt①②③④，act_buf 仍是 FF array）的
後端 P&R。floorplan 1100×1000 µm，2 顆 psum SRAM macro。

### 驗證 — 全部乾淨 ✅
| 項目 | 結果 |
|------|------|
| DRC | 0 violations ✅ |
| Connectivity | Found no problems or warnings ✅ |
| Antenna | No Violations Found ✅ |

### 時序（target 12 ns / 83 MHz）
| 模式 | WNS | 結果 |
|------|-----|------|
| Setup | **+0.861 ns** | MET ✅ |
| Hold  | **+2.111 ns** | MET ✅ |

關鍵路徑：`u_ctrl/state_reg → u_sa/acc_reg[*][39]`（SA 40-bit 累加器）。

> ⚠️ **重點發現**：合成時 critical path ~7 ns，P&R 後變成 **~11 ns**
> （12 − 0.861 − setup/uncert）。**+4 ns 全是繞線延遲** —— v3 設計很大
> （268 K cells、1100×1000 µm），act_buf 的 FF array（260 K µm²）散佈整個
> floorplan，它的輸出餵進 SA，繞線又長又多。所以 **v3(FF) 只能到 ~83–90 MHz，
> 不像 v2 能到 141 MHz**。

### 功耗（default activity）
| 類別 | Power (mW) | 佔比 |
|------|-----------|------|
| Combinational | 71.61 | 83.8% |
| Sequential | 9.57 | 11.2% |
| Macro（psum SRAM）| 2.34 | 2.7% |
| Clock | 1.93 | 2.3% |
| **Total** | **85.45 mW** | 100% |

Placement density 48.5%。

### FPS
12,281,668 cycles/inference：
| 頻率 | FPS |
|------|-----|
| 83 MHz（P&R target） | **6.76 fps** |
| ~90 MHz（WNS 上限） | ~7.4 fps |

### 成效分析 + 需要改良嗎？

**成效**：流程完整收斂、DRC/timing/antenna 全乾淨 —— 是個有效、可交付的結果。
比 v2（4.85 fps）快約 1.4×，主因是 cycle 數少一半（opt①②③④）。

**但有兩個明顯可改良處**：

1. **頻率被 FF act_buf 拖累** —— v3(FF) 只到 ~90 MHz，遠低於 v2 的 141 MHz。
   原因：260 K µm² 的 FF act_buf 散佈整個 die，巨大的 read/write mux 網路
   造成超長繞線 → P&R 後 critical path 從 7 ns 爆到 11 ns。
   → **解法 = act_buf 換 SRAM macro**（已於 RTL 完成並驗證 50 層 MATCH）：
     act_buf 收斂成一顆 97 K µm² 的 macro、registered 讀取取代巨型組合 mux
     → 繞線變短、時序乾淨，預期頻率明顯回升。

2. **功耗 85 mW 偏高** —— Combinational 佔 83.8%，主要是 act_buf FF array +
   144-MAC SA。act_buf 換 SRAM 後 cell 數大幅下降 → 功耗也會跟著降。

**結論**：v3(FF) 後端結果**可交付但非最佳**。真正的改良 = **act_buf SRAM 版**
（RTL 已完成、OpenRAM macro 已產），重新合成 + 重跑後端即可拿到
更高頻率、更小面積、更低功耗的 3-macro 版本。

---

## v3 P&R 結果（SRAM act_buf 版，`innovus.log11`，2026-05-18）

act_buf 換成 OpenRAM SRAM macro（192-bit×64）、psum_b 移除 → **2-macro 設計**
（psum SRAM_A + act_buf SRAM）。netlist：`mfn_frontend_top_v3_syn.v`（87,190 cells）。

### 驗證
| 項目 | 結果 |
|------|------|
| DRC | **1 violation** ⚠️（見下）|
| Connectivity | Found no problems ✅ |
| Antenna | No Violations Found ✅ |

**那 1 個 DRC**：`OFFGRID — u_act_buf/CTS_29 (metal3)`。根因是 **OpenRAM 產生的
act_buf SRAM LEF 的 pin 座標不在 manufacturing grid 上**（log 裡的 `IMPLF-82`：
`din0` pin y=1.0375 / 1.1725 µm，非格點整數倍）。router 接到 off-grid pin →
clock 線變 off-grid。屬 OpenRAM 產生工具的瑕疵；真正 tape-out 需把 LEF pin
座標 snap 到格點。Innovus 容忍此錯誤、流程仍完整跑完。

### 時序（target 12 ns / 83 MHz）
| 模式 | WNS | 結果 |
|------|-----|------|
| Setup | **+0.549 ns** | MET ✅ |
| Hold  | **+5.357 ns** | MET ✅ |

### 功耗（default activity）
| | SRAM 版 | FF 版（對照）|
|--|--------|-------------|
| Total Power | **44.97 mW** | 85.45 mW |
| | Internal 21.81 / Switching 19.27 / Leakage 3.89 | |

→ act_buf 從 168K FF 變成一顆 macro，**功耗砍 47%**。

Placement density：**21.16%**。

### 瓶頸分析 ⚠️

| 階段 | Critical path |
|------|--------------|
| 合成 | ~7 ns |
| **P&R 後** | **~11.45 ns**（12 − 0.549）→ 實際最高 ~87 MHz |

**P&R 多了 ~4.5 ns，全是繞線延遲。** 根因：

> **Floorplan 過大** —— `run_innovus_3.tcl` 的 floorplan 1100×1000 µm 是照
> FF 版（455K µm²）設的。SRAM 版設計小一半（cell 面積僅 ~190K µm²），
> 塞進同樣大的 die → **density 只有 21%** → cell 散佈整個大晶片 →
> 每條 net 都很長 → 繞線延遲爆增。

→ **這是頻率瓶頸，而且容易修**：把 floorplan 縮小到 density ~45–50%
（SRAM 版只要 ~190K cell + 2 macro 163K µm² → 建議 ~800×700 µm 核心），
繞線變短、頻率應明顯回升（朝 ~7 ns 合成值靠近）。

### FPS 現況

SRAM 版 cycles = 13,772,816（2-cycle act_buf latency 的 RADDR2 比 FF 版多）：

| | cycles | 頻率（P&R 實測）| FPS |
|--|--------|----------------|-----|
| v3 FF 版 | 12,281,668 | ~83–90 MHz | ~6.8 |
| **v3 SRAM 版（現況）** | 13,772,816 | ~87 MHz | **~5.95** |
| v3 SRAM 版（縮 floorplan 後估計）| 13,772,816 | ~110 MHz | ~8.0 |

> ⚠️ **目前 SRAM 版 FPS（5.95）反而比 FF 版（6.8）低** —— 因為 cycle 數較多
> 又被過大 floorplan 拖頻率。SRAM 版的價值在**面積（−58%）與功耗（−47%）**；
> 要在 FPS 也勝出，**必須縮小 floorplan** 把頻率拉上來。

### 結論 + 下一步
- act_buf SRAM 化：功能對、面積/功耗大幅下降、DRC 僅 1 個結構性 off-grid。
- **關鍵待辦**：縮小 `run_innovus_3.tcl` 的 floorplan（→ ~800×700 µm）重跑，
  把 density 拉到 ~48%、頻率拉回 ~110 MHz。
- act_buf SRAM LEF 的 off-grid pin：若要 DRC 全清零，需修 LEF（pin 座標
  snap 到 manufacturing grid）。

---

## v3 P&R 結果（SRAM 版 — floorplan/DRC/CTS 修正後，`innovus.log2`，2026-05-19）

修正後重跑：act_buf LEF grid-snap、floorplan 1100×1000→800×700、CTS 加 skew/slew target。

### 驗證 — 全清 ✅
| 項目 | log11（修正前）| **log2（修正後）** |
|------|---------------|-------------------|
| DRC | 1（OFFGRID）| **0** ✅ |
| Connectivity / Antenna | 0 / 0 | 0 / 0 ✅ |
| Placement density | 21% | **51.8%** ✅ |
| Clock skew | 0.065 ns | **0.060 ns**（insertion delay 平均 0.44→0.37 ns，sd 0.015→0.009）✅ |

→ off-grid DRC、floorplan、clock 三項修正全部生效。

### 時序 / 頻率 / FPS
| 項目 | 數值 |
|------|------|
| Setup WNS @ 12 ns | **+0.464 ns** → MET |
| Hold WNS | +5.041 ns → MET |
| Critical path | `psum SRAM dout1 → activation → clamped_s1_reg`（半週期路徑）|
| 實際 critical path | ~11.5 ns → **最高頻率 ~87 MHz** |
| 功耗 | 45.37 mW |

### Cycle / Frequency / FPS 總表（v3）
| 版本 | Cycles/inference | 頻率 | **FPS** |
|------|-----------------|------|---------|
| v3 FF act_buf | 12,281,668 | ~90 MHz | ~6.8 |
| **v3 SRAM act_buf（現況）** | **13,772,816** | **~87 MHz** | **~6.0** |
| v3 SRAM @ 150 MHz（目標）| 13,772,816 | 150 MHz | 10.9 |

### 瓶頸：psum SRAM 半週期路徑
critical path 是 `psum SRAM dout1 → activation`。psum SRAM（OpenRAM）的
`dout1` 在 **negedge** 才出 → activation 邏輯（PReLU 乘法/clamp/residual，~5.5 ns）
只有半個 cycle（6 ns）可用 → 卡在 ~87 MHz。這是與 act_buf 同一類的
OpenRAM negedge-dout 半週期問題。

### 要破 150 MHz（6.67 ns period）需做的事
critical path 要從 ~11.5 ns 砍到 <6.67 ns，需深度 pipeline：
1. **psum SRAM 讀出加一級暫存** → activation 拿回整個 cycle（+1 cycle latency）
2. **activation 模組再切細 pipeline**（乘法 / clamp / residual 分級）
3. **SA 40-bit accumulator 路徑加 pipeline**
4. 每加一級 pipeline → cycle 數增加，需重驗 50 層 MATCH
→ 150 MHz 是進階目標，屬多輪 RTL pipeline 工程。第一步（psum 輸出暫存）
   預期可先到 ~110–120 MHz。

---

## v3 P&R 結果（150 MHz 達成版，`innovus.log4`，2026-05-19）

frontend 為 §35 完成 Stage 1 + Stage 2 後，將 SDC period 12.0 → **6.67 ns**
重做 Genus + Innovus，直接打進 150 MHz 目標。

### RTL 改動摘要（frontend §35 詳列）
- `mfn_activation.sv`：2-stage → **4-stage** pipeline
  - **Stage 0 register**：吃掉 psum SRAM 的 negedge-dout，讓 stage-1 shift+clamp 拿到整個 cycle
  - **Stage 2 拆 2A / 2B**：把 16×16 PReLU mult 跟後續 MUX+residual add+clamp 分開，每級延遲降到 6.67 ns 內
  - valid_out 比 valid_in 晚 **4 cycles**（原本 2 cycles）
  - 加入 `prelu_prod_s2a`、`clamped_s2a`、`has_prelu_s2a`、`layer_is_res_s2a`、`residual_s2a`、`valid_s2a` 等中繼 register
- `mfn_controller_v3.sv`：state enum 補 `S_NEXT_LAYER_WAIT2` / `S_NEXT_LAYER_WAIT3`
  → `S_SPATIAL_LOOP → S_NEXT_LAYER` 拉成 3-cycle wait，等 4-stage pipeline drain 完
  （否則最後一個 pixel 的 `valid_out` 跟 TB 的 `$writememh` 競態 → 50 層全 mismatch）
- `constraints_v3.sdc`（syn + backend 各一份）：`create_clock -period 12.0` → **`6.67`**，
  `set_input_delay 2.4` / `set_output_delay 2.4` → **1.33**
- `run_innovus_3.tcl`、`mfn_frontend_top_v3.view`：標題改 150 MHz；不改 floorplan / SRAM 配置（沿用 §30 全清的 800×700）

### Genus synth @ 6.67 ns
| 項目 | 數值 |
|------|------|
| WNS | **+1.121 ns** ✓ MET |
| Critical path | `u_act_buf/act_out_reg → u_sa/mul_55_31 (16×16) → CSA tree → u_sa/acc_reg[0][39]` |
| Data delay | 5,393 ps |
| Cells | 86,834 |
| Area | 334,956 µm² |
| Power（default activity） | 143.58 mW |

### Innovus P&R @ 6.67 ns — 全清 ✅
| 項目 | 數值 |
|------|------|
| DRC | **0** ✅ |
| Connectivity / Antenna | 0 / 0 ✅ |
| Placement density | **51.99%** |
| **Setup WNS** | **+0.688 ns** |
| **Hold WNS** | **+0.440 ns** |
| Setup / Hold TNS | 0.000 / 0.000 |
| Critical path（post-route）| SA mult + CSA tree（同 syn）|
| Data delay（post-route）| 6.234 ns（syn 5.39 → +0.84 ns 繞線）|
| Useful clock skew | +0.45 ns（capture 端 latency 多幫忙 setup）|
| Clock insertion delay | 0.309–0.369 ns（avg 0.345，sd 0.011）|
| Clock skew | 0.059 ns（target 0.050 接近達成）|
| Total power | **77.87 mW**（internal 38.81 + switching 35.16 + leakage 3.89）|

### Cycle / Frequency / FPS / Energy 總表（v3 演進）
| 版本 | Cycles | freq | FPS | Power | mJ/inf |
|------|--------|------|-----|-------|--------|
| v3 SRAM @ 12 ns（§30，2-stage activation）| 13,772,816 | ~87 MHz | 6.0 | 45.37 mW | 7.56 |
| **v3 SRAM @ 6.67 ns（4-stage activation）** | **13,772,916** | **150 MHz** | **10.89** | **77.87 mW** | **7.15** |

→ 頻率 +72% 對應 power +72%（dynamic 跟 freq 成比，leakage 維持）→ **energy/inference 沒升反略降**。
cycle 數 +100（+0.0007%）幾乎沒影響。

### 等效最高頻率 & 進一步空間
post-route slack +0.688 ns → 等效 ~167 MHz（11% headroom）。

→ 接著加 §35 **Stage 3**（SA mult+CSA tree 後加 row_dot_reg）並推到 5.75 ns，見下一節。

---

## v3 P&R 結果（174 MHz / Stage 3 SA pipeline，`innovus.log7`，2026-05-20）

frontend 多做 §35 **Stage 3**（SA mult+CSA tree 後加 register），SDC 從 6.67 → **5.75 ns** 重做 syn + P&R。

### RTL 改動摘要
- `mfn_sa_12x12.sv`：comb stage（mul + tree → `row_dot[r]`）跟 acc add 切兩段。
  - 新增 `row_dot_reg[12]`（12 × 40-bit = 480 FF）+ `enable_d`（1 bit）
  - acc 更新從 `if (enable) acc += row_dot` → `if (enable_d) acc += row_dot_reg`
  - `clear` 不經 pipeline（bias 直入 acc）—— controller 的 S_BIAS_LOAD 不會緊接 S_*_COMPUTE，沒 race
- `mfn_controller_v3.sv`：新增 state `S_DW_DRAIN`
  - PW (`S_NEXT_CIN`) 跟 DW12 (`S_DW12_KP_NEXT`) 已天然有 drain cycle
  - **唯一例外**是 global DW（`S_DW_COMPUTE` 直接跳 `S_DW_WRITEBACK`），加 1 cycle drain
  - 影響：layer 48（linear7，512 out-ch global DW）+512 cycles，其他 49 層 0 變化
- `constraints_v3.sdc`（syn + backend）：6.67 ns → **5.75 ns**，I/O delay 1.33 → 1.15
- `run_innovus_3.tcl` / `mfn_frontend_top_v3.view`：標題 + tail puts 更新

### Cycle 影響
| 階段 | Total cycles | Δ vs prev |
|------|-------------|-----------|
| Stage 0+2 後 | 13,772,916 | — |
| **+ Stage 3** | **13,773,428** | **+512**（+0.0037%）|

### Genus synth @ 5.75 ns
- WNS 通過，**critical path endpoint 從 `acc_reg` 移到 `row_dot_reg_reg`** ← Stage 3 register 生效
- 合成器把 16×16 mult + 12-tap CSA tree 合併為一棵 Wallace tree（`csa_tree_add_71_27`），路徑裡看不到獨立 `mul_55_31` cell

### Innovus P&R @ 5.75 ns — 全清 ✅
| 項目 | 數值 |
|------|------|
| DRC | **0** ✅ |
| Connectivity / Antenna | 0 / 0 ✅ |
| Placement density | **52.92%** |
| **Setup WNS** | **+0.565 ns** |
| **Hold WNS** | **+0.483 ns** |
| Setup / Hold TNS | 0 / 0 |
| Critical path（post-route）| `u_act_buf/act_out_reg/QN → CSA tree → u_sa/row_dot_reg_reg[4][36]/SI` |
| Data delay | 5.503 ns |
| Other End Arrival | 0.477 ns（capture clock latency，幫忙 setup）|
| Clock insertion delay | 0.377–0.445 ns（avg 0.417，sd 0.013）—— 比 150 MHz 版（0.309–0.369）長一點，多了 Stage 3 reg leaves |
| Clock skew | 0.068 ns（target 0.050 微超 0.018 ns，不影響 timing）|
| **Total power** | **88.20 mW**（Internal 43.49 + Switching 40.75 + Leakage 3.96）|

### Cycle / Frequency / FPS / Energy 演進總表

| 版本 | Cycles | freq | FPS | Power | µJ/inf | WNS |
|------|--------|------|-----|-------|--------|-----|
| v3 SRAM @ 12 ns（§30，2-stage activation）| 13,772,816 | 87 MHz | 6.0 | 45.37 mW | 7.56 | +0.464 ns |
| Stage 0+2（4-stage activation @ 6.67 ns）| 13,772,916 | 150 MHz | 10.89 | 77.87 mW | 7.15 | +0.688 ns |
| + Stage 3 SA pipeline @ 5.75 ns | 13,773,428 | 174 MHz | 12.63 | 88.20 mW | 6.98 | +0.565 ns |
| **+ 5.0 ns push（RTL 不動）** | **13,773,428** | **200 MHz** | **14.52** | **99.13 mW** | **6.83** | **+0.257 ns** |

→ vs §30 起點：**freq +130%、FPS +142%、energy −9.7%**。
頻率 87→200 MHz +130%，power 45→99 mW 也跟著 +118%（dynamic ∝ freq），cycle +0.004% 幾乎沒影響，
所以 **µJ/inf 反而連續下降**（150→174→200 MHz 階段：7.15 → 6.98 → 6.83 µJ）。

---

## v3 P&R 結果（200 MHz 收尾版，`innovus.log`，2026-05-20）

frontend RTL **不變**（保持 Stage 0+2+3），只把 SDC 從 5.75 → **5.0 ns** 重做 syn + P&R。

### Genus synth @ 5.0 ns
- WNS **+0.177 ns**（邊緣警告，原本預估 P&R 會 fail）
- Critical path 同 5.75 ns：`u_act_buf/act_out_reg → CSA tree → u_sa/row_dot_reg`
- Genus 在 5.0 ns 下 cells +1.4%（86,834 → 88,018），多用 X2/X4 drive

### Innovus P&R @ 5.0 ns — 全清 ✅ **賭贏**
| 項目 | 數值 |
|------|------|
| DRC / Conn / Antenna | 0 / 0 / 0 ✅ |
| Placement density | **52.87%** |
| **Setup WNS** | **+0.257 ns**（**比 syn 還升 0.08 ns**！）|
| **Hold WNS** | **+0.508 ns** |
| Setup / Hold TNS | 0 / 0 |
| Critical path | `u_act_buf/act_out_reg → CSA tree → u_sa/row_dot_reg_reg[0][33]/SI` |
| Data delay | 5.051 ns（syn 4.67 → P&R +0.38 ns，**比 5.75 ns 的 +0.84 ns 還少**）|
| Other End Arrival | 0.475 ns（useful clock skew 倒貼 setup）|
| Clock insertion delay | 0.357–0.426 ns（avg 0.409, **sd 0.012**）|
| Clock skew | 0.069 ns（target 0.050）|
| **Total power** | **99.13 mW**（Internal 48.77 + Switching 46.40 + Leakage 3.96）|

### 為何 P&R 比 syn 還好？

兩個合計把 syn 的 +0.177 ns 推到 P&R 的 +0.257 ns：
1. **走線比 Genus 預估短** —— floorplan 800×700 不擠（density 52.87%）、繞線延遲 0.38 ns < 預估 0.84 ns
2. **useful clock skew 0.475 ns** —— Innovus CCOpt 給 capture 端 clock 較長 latency，等於把 setup window 拉大 0.4+ ns

### Clock 平衡度
- Insertion delay sd = 0.012 ns（很 tight）
- skew 0.069 ns（target 0.050，差 0.019）
- 整體已算平衡。要再壓 skew → `target_skew 0.030` 重 CTS，但目前 timing 已 met，沒必要

### Floorplan 800×700 vs 750×750（方形）討論
| | 現況 800×700 | 方形 750×750 |
|---|---|---|
| Core 面積 | 560,000 µm² | 562,500 µm²（+0.4%）|
| Stdcell util | 49.9% | 49.5% |
| Max diagonal | 1,063 µm | 1,060 µm |
| Clock tree depth | ~7-8 levels | ~7-8 levels |

→ **改方形沒實質收益**，timing/clock balance 幾乎不變。現況 800×700 + DRC=0 + +0.257 ns slack 已是最佳。

---

## v3 P&R 結果（200 MHz / 720×720 area-shrink 版，`innovus.log2`，2026-05-20）

RTL 跟 SDC 都不動，只把 floorplan 從 800×700 縮成 **720×720**（act_buf 上推 10 µm 變 (10, 545)），
驗證 area / power 還能再壓多少、timing 會掉多少。

### tcl 變動
| | 800×700 | **720×720** |
|---|---------|-------------|
| `floorPlan -s` | `800 700 5 5 5 5` | **`720 720 5 5 5 5`** |
| act_buf 位置 | `(10, 535)` | **`(10, 545)`**（上推 10 µm 留 routing channel）|
| act_buf blockage | `{5 530 655 692}` | **`{5 540 655 702}`** |
| Power stripe 註解 | "800-wide → ~16 pairs" | "720-wide → ~14 pairs"（不用實質調整）|

### Innovus 結果 — 全清 ✅
| 項目 | 800×700 | **720×720** | Δ |
|------|---------|-------------|---|
| Core 面積 | 560,000 µm² | **518,400** | **−7.4%** ✓ |
| Placement density | 52.87% | 59.49% | +6.6 pp |
| DRC / Conn / Antenna | 0 / 0 / 0 | 0 / 0 / 0 | 全清 ✅ |
| **Setup WNS** | +0.257 ns | **+0.089 ns** | **−0.168 ns** ⚠ |
| Hold WNS | +0.508 ns | +0.437 ns | −0.071 ns |
| Setup / Hold TNS | 0 / 0 | 0 / 0 | — |
| Data delay | 5.051 ns | **5.172 ns** | +0.121 ns（router 為避擠多繞）|
| Useful clock skew | 0.475 ns | 0.427 ns | −0.048 ns |
| Insertion delay | avg 0.409, **sd 0.012** | avg **0.348, sd 0.009** | **clock 短了 60 ps、變異度更小** ✓ |
| Clock skew | 0.069 ns | 0.067 ns | 略好 |
| **Total power** | 99.13 mW | **96.32 mW** | **−2.81 mW (−2.8%)** ✓ |
| Switching power | 46.40 mW | **43.76 mW** | **−5.7%**（線短了，C↓）|
| **µJ/inference** | 6.83 | **6.63** | **−2.9%** ✓ |

### 解讀
- **真實收益**：area −7.4%、switching power −5.7%、energy −2.9%、clock tree 更短更平衡
- **代價**：setup WNS 從 +0.257 → +0.089 ns，data path +0.121 ns（router 在 59% density 下要繞）
- **為何 data path 反而變長**：density 53% → 59% 把繞線壓緊，router 為了避擠用更長 detour；同時 CCOpt 在較緊 floorplan 下能撈到的 useful skew 減少 0.048 ns
- 兩個 effect 加起來 0.121 + 0.048 = 0.169 ns，**剛好對應 −0.168 ns 的 WNS 損失**

### Floorplan 三種選擇對比

| | 800×700 | **720×720** | 750×750（沒實跑）|
|---|---------|-------------|-------------------|
| 面積 | 560 K µm² | **518 K** | 562 K |
| Density | 53% | 59% | 52% |
| Setup WNS | +0.257 | +0.089 | ~+0.25（推估）|
| Power | 99.13 mW | **96.32 mW** | ~99 mW |
| Energy/inf | 6.83 µJ | **6.63 µJ** | ~6.83 µJ |
| margin 風險 | 安全 | 邊緣（1.8% headroom）| 安全 |
| 結論 | 保險版 | **省面積收尾** | 沒理由用 |

### 最終 v3 演進總表（**最終版**）

| 階段 | freq | Cycles | FPS | Power | µJ/inf | WNS | Floorplan |
|------|------|--------|-----|-------|--------|-----|-----------|
| §30（2-stage activation）| 87 MHz | 13,772,816 | 6.0 | 45.37 mW | 7.56 | +0.464 ns | 800×700 |
| Stage 0+2 @ 6.67 ns | 150 MHz | 13,772,916 | 10.89 | 77.87 mW | 7.15 | +0.688 ns | 800×700 |
| + Stage 3 @ 5.75 ns | 174 MHz | 13,773,428 | 12.63 | 88.20 mW | 6.98 | +0.565 ns | 800×700 |
| + 5.0 ns push | 200 MHz | 13,773,428 | 14.52 | 99.13 mW | 6.83 | +0.257 ns | 800×700 |
| **+ 720×720 area-shrink** | **200 MHz** | **13,773,428** | **14.52** | **96.32 mW** | **6.63** | **+0.089 ns** | **720×720** |

→ vs §30 起點：**freq +130%、FPS +142%、energy −12.3%、area −7.4%**。
最後兩階都是「不動 RTL，只動 SDC / floorplan」純後端收益。

### Headroom 跟可能的下一步（按 CP 值排序）
1. **跑 GL sim** 用 final netlist 驗 50 層 ← **必做**
2. 留現狀 720×720 收尾（200 MHz / 14.52 fps / 96 mW / 6.63 µJ） ← **建議**
3. `set_clock_uncertainty` 0.1 → 0.05 → +0.05 ns slack（保險用，720 邊緣 +0.089 變 +0.14）
4. Rotate act_buf R90 + halo —— 預估 +100 ps slack，但要 1 輪 P&R 試
5. 加 `auto_clock_gating` → dynamic power −10~20%（leakage 才 4%，著重在 dynamic）
6. 4.75 ns 再 push（210 MHz）：720 已 +0.089 ns，再緊可能 fail
7. **Stage 3.5**（per-PE product reg）→ 280 MHz 理論值，是真正的下一階段，但屬深 pipeline 工程
