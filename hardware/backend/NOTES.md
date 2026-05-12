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

## v2 結果 (`run_innovus_2.tcl`) — 進行中

### v2 新增項目
1. **CTS NDR**：
   - `CTS_2W1S`（leaf, M1-M4）：雙倍線寬 / 單倍間距 → 降低 leaf 端 RC，減少 skew
   - `CTS_2W2S`（trunk, M7-M10）：雙倍線寬 / 雙倍間距 + VSS shield → 低 RC trunk + EMI 隔離
2. **`timeDesign` before each `optDesign`**：post-CTS 和 post-route 各加一次 timing snapshot
3. **`addFiller` before routing**：FILLCELL_X32→X1，保持 N-well continuity 與 M1 rail bridging

### 預期改善
- Clock skew 降低（NDR 使 trunk 更一致）
- `optDesign` 有更好的 timing 起點（`timeDesign` 先報告）
- DFM 改善（filler 先插）

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
# PG netlist（已存在，不需重跑）
make pg

# v1 P&R
make pnr

# v2 P&R（NDR + timeDesign + filler-first）
tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && innovus -files run_innovus_2.tcl"
```

## 輸出檔案對照

| 檔案 | v1 | v2 |
|------|----|----|
| 設計資料庫 | `mfn_frontend_top_final.enc` | `mfn_frontend_top_v2_final.enc` |
| Netlist | `mfn_frontend_top_final_nophy.v` | `mfn_frontend_top_v2_final_nophy.v` |
| Timing report | `pnr_timing.rep` | `pnr_v2_timing.rep` |
| Power report | `pnr_power.rep` | `pnr_v2_power.rep` |
| DRC | `mfn_frontend_top.drc.rpt` | `mfn_frontend_top_v2.drc.rpt` |
