# Innovus P&R Notes — mfn_frontend_top

## 環境
- Tool: Cadence Innovus 16.20-p002_1
- PDK: NangateOpenCellLibrary / FreePDK45 (45 nm)
- Target clock: 100 MHz (10 ns period)
- Input netlist: `mfn_frontend_top_syn_pg.v` (Genus 合成 + add_pin.py 加 VDD/VSS port)
- MMMC: `mfn_frontend_top.view` (single corner: tt, 1.1V, 25°C)

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
