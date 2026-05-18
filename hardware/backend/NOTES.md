# Innovus P&R Notes — mfn_frontend_top

## 環境
- Tool: Cadence Innovus 16.20-p002_1
- PDK: NangateOpenCellLibrary / FreePDK45 (45 nm)
- MMMC: 單一 corner（tt, 1.1V, 25°C）
- Target clock：v1 = 100 MHz；v2 / v3 = 125 MHz（8 ns）

---

## 總覽：v1 → v2 → v3

| | v1 | v2 | v3（合成完成、後端待跑） |
|--|----|----|------|
| 計算單元 | **單一 9-MAC 點積**（`mfn_mac_array`，9 乘法器，算 1 個 output ch 的 3×3）、ripple-carry 加法器、flat netlist | **雙 9-MAC**（2×`mfn_mac_array`，18 乘法器，並行算 2 個 output ch）、40-bit CLA、OpenRAM psum SRAM macro | **12×12 = 144-MAC 陣列**（`mfn_sa_12x12`，output-stationary）、act_buf、12-ch 寬載入；opt①②③④ |
| Cycles / inference | 43,158,478 | 25,768,847 | **12,281,668**（v3++ opt①②③④） |
| 合成 cell 數 / 面積 | — | 137,976 / 479k µm² | 268,231 / 455k µm² |
| P&R 狀態 | ✅ 完成 | ✅ 完成（DRC 0、timing met） | `run_innovus_3.tcl` 已備妥，**待跑** |
| DRC / Conn / Antenna | 0 / 0 / 0 ✅ | 0 / 0 / 0 ✅ | 待跑 |
| Timing | WNS +3.611 ns @100 MHz | setup +0.908 / hold +0.507 ns @125 MHz | 合成 +4.84 ns @83 MHz（critical ~7 ns，同 v2） |
| 功耗 | 26.66 mW | 11.35 mW | 待 P&R |
| FPS | ~2.3 fps @100 MHz | **4.85 fps @125 MHz** | ~10 fps @125 MHz（估） |

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
