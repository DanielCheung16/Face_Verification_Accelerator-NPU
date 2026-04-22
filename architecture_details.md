# MobileFaceNet 硬體架構與資料流詳解

為了硬體設計 (VLSI / SystemVerilog)，你需要非常精確地知道「每一個運算步驟的 Feature Map 大小」以及「Kernel 參數」。這份文件將模型一層一層徹底拆解。

---

## 一、 圖片是如何餵進去的 (Input Stage)

1. **原圖來源**：測試腳本先讀取標準的 `.jpg` 影像，將其裁切/縮放至 `112 x 96` 像素。
2. **預處理**：Python 會將每個像素點的 RGB 值（原本是 0~255）減去平均值、除以標準差，轉換為均值為 0 的小數 (Float32)。
3. **硬體量化 (INT16)**：接著，我們將這些小數乘上 `1024` ($2^{10}$)，並四捨五入為 `int16_t` 整數。
4. **傳遞給 C 語言**：Python 把這 $3 \times 112 \times 96 = 32,256$ 個 `int16_t` 數字攤平寫入 `tmp_in_fixed.txt`。C 程式透過 `fscanf` 讀取並填入名為 `x` 的 `Tensor3D` 記憶體空間中。

> [!NOTE]
> 你的硬體第一張 Feature Map (`SRAM_A`) 的初始狀態就是這 **32,256 筆 16-bit 資料**。
> 資料排列順序為 **Channel-Major (CHW)**：先放完 R 通道的所有像素，接著是 G 通道，最後是 B 通道。

---

## 二、 卷積層詳細解析 (Layer-by-Layer Breakdown)

整個模型可以拆解為 **58 個實體卷積層** (包含 Pointwise 和 Depthwise)。以下列出每一層的進出規格：

### 1. 前端特徵提取 (Stem)
| 階層名稱 | 卷積類型 | Kernel | Stride | 輸入尺寸 (C x H x W) | 輸出尺寸 (C x H x W) | PReLU |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **conv1** | 標準 2D 卷積 | 3x3 | **2** | `3 x 112 x 96` | **`64 x 56 x 48`** | 有 |
| **dw_conv1**| Depthwise | 3x3 | 1 | `64 x 56 x 48` | `64 x 56 x 48` | 有 |

> [!IMPORTANT]
> 注意 `conv1` 的 Stride=2。因為這步跨步運算，長寬 `112x96` 被砍半成 `56x48`。
> 這裡出現了本模型**最大的 Feature Map 體積**：$64 \times 56 \times 48 = 172,032$ 個數字。
> 你的 SRAM 容量至少要能容納 $172,032 \times 2 \text{ bytes (16-bit)} \approx \mathbf{344 \text{ KB}}$ 才能裝下一張圖。

---

### 2. 瓶頸層群組 (Bottleneck Blocks)
瓶頸層總共有 15 個 Block。每個 Block 固定包含 3 個動作：
1. **PW1 (Pointwise 1x1)**：把通道數 (Channel) 膨脹。
2. **DW (Depthwise 3x3)**：在膨脹的通道上做空間濾波 (Stride 決定長寬是否減半)。
3. **PW2 (Pointwise 1x1)**：把通道數壓縮回指定大小 (無 PReLU)。
4. *如果有 Shortcut，PW2 的輸出會與輸入做矩陣相加。*

**A. 第一組 Bottleneck (重複 5 次)**
| Block | 動作 | Kernel | Stride | 輸入 | 輸出 | 備註 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Block 0** | PW1 -> DW -> PW2 | 1x1, 3x3, 1x1 | **2** | `64 x 56 x 48` | `64 x 28 x 24` | DW 做降採樣 (Stride 2) |
| **Block 1~4** | PW1 -> DW -> PW2 | 1x1, 3x3, 1x1 | 1 | `64 x 28 x 24` | `64 x 28 x 24` | 具有 Shortcut (相加) |
*內部膨脹通道數：`128` (64 x 2 倍)*

**B. 第二組 Bottleneck (重複 1 次)**
| Block | 動作 | Kernel | Stride | 輸入 | 輸出 | 備註 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Block 5** | PW1 -> DW -> PW2 | 1x1, 3x3, 1x1 | **2** | `64 x 28 x 24` | `128 x 14 x 12` | DW 做降採樣 (Stride 2) |
*內部膨脹通道數：`256` (64 x 4 倍)*

**C. 第三組 Bottleneck (重複 6 次)**
| Block | 動作 | Kernel | Stride | 輸入 | 輸出 | 備註 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Block 6~11**| PW1 -> DW -> PW2 | 1x1, 3x3, 1x1 | 1 | `128 x 14 x 12` | `128 x 14 x 12` | 具有 Shortcut (相加) |
*內部膨脹通道數：`256` (128 x 2 倍)*

**D. 第四組 Bottleneck (重複 1 次)**
| Block | 動作 | Kernel | Stride | 輸入 | 輸出 | 備註 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Block 12** | PW1 -> DW -> PW2 | 1x1, 3x3, 1x1 | **2** | `128 x 14 x 12` | `128 x 7 x 6` | DW 做降採樣 (Stride 2) |
*內部膨脹通道數：`512` (128 x 4 倍)*

**E. 第五組 Bottleneck (重複 2 次)**
| Block | 動作 | Kernel | Stride | 輸入 | 輸出 | 備註 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Block 13~14**| PW1 -> DW -> PW2 | 1x1, 3x3, 1x1 | 1 | `128 x 7 x 6` | `128 x 7 x 6` | 具有 Shortcut (相加) |
*內部膨脹通道數：`256` (128 x 2 倍)*

---

### 3. 尾端聚合層 (Head)
所有的瓶頸層結束後，特徵圖大小來到 `128 x 7 x 6`。接著要將它壓平轉換為 128D 的一維特徵。

| 階層名稱 | 卷積類型 | Kernel | Stride | 輸入尺寸 | 輸出尺寸 | PReLU |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **conv2** | PW (1x1 卷積) | 1x1 | 1 | `128 x 7 x 6` | `512 x 7 x 6` | 有 |
| **linear7** | DW (Global Pooling) | **7x6** | 1 | `512 x 7 x 6` | **`512 x 1 x 1`** | 無 |
| **linear1** | PW (1x1 卷積) | 1x1 | 1 | `512 x 1 x 1` | **`128 x 1 x 1`** | 無 |

> [!TIP]
> **為何叫 linear7？**
> 在 PyTorch 中，這通常是用 `Global Average Pooling` 把 `7x6` 壓扁成 `1x1`。但在我們的網路設計中，為了節省除法電路，我們直接用了一個大小等同於畫面的 **`7x6` Depthwise Convolution** 把它 "蓋住" 壓扁。
> 最終出來的 `128 x 1 x 1` 就是人臉特徵的 Embedding Vector。
