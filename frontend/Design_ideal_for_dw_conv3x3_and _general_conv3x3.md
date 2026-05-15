# 总设计思路

## 1. PE array 设计
本设计只使用一个 `3×3 PE array` 来实现所有 `DWConv3×3` 和普通 `Conv3×3`。
该 array 采用普通 MAC 结构。每个 PE 负责一个 window element 和 filter element 的乘法，例如：

```text
PE00 = A00 × W00
PE01 = A01 × W01
...
PE22 = A22 × W22
````
因此，一个 `3×3 PE array` 一次完成 9 个 MAC，对应一个 `3×3 filter` 和一个 `3×3 activation window` 的 dot product。


## 2. 按 channel 方向计算

为了配合 `Conv1×1`，global buffer 中的 activation 采用 `HWC` 存储方式：

```text
I[y][x][c]
```

也就是同一个 pixel 下的多个 channel 连续存储。

同时，global buffer 一次读取宽度为：

```text
128 bits = 16 Bytes = 16 个 INT8 channel
```

如果按照传统 sliding window 的方式先固定 `ic`，那么每次 128-bit 读取中只会使用 1 Byte，剩下 15 Bytes 会被浪费。这样不仅降低读取带宽利用率，也会增加加载延时。并且由于输出仍然需要写回成 HWC 格式，若每次只生成 1 Byte output，也无法高效利用 128-bit 写宽。

因此，本设计选择沿 channel 方向计算。也就是说，先固定空间位置：

```text
output[y][x]
```

然后依次计算该位置下连续 16 个 output channel 的结果。



## 3. Activation buffer 设计

对于一个固定的 `output[y][x]`，需要读取一个 `3×3 activation window`。

由于每次读取 128 bits，所以一个 window 需要：

```text
9 × 128-bit activation words
```

也就是：

```text
9 × 16 Bytes
```

每个 128-bit word 包含同一个空间位置下的 16 个连续 channel。

因此 activation buffer 可以设计为：

```text
9 × 16 Bytes
```

为了隐藏 activation load latency，采用 ping-pong buffer：

```text
activation buffer A：用于当前 window 计算
activation buffer B：同时加载下一个 window
```

所以总 activation buffer 大小为：

```text
2 × 9 × 16 Bytes
```


## 4. Weight buffer 设计

当 `output[y][x]` 的 16 个 channel 计算完成后，下一步会移动到下一个空间位置。但对于 DWConv3×3 来说，filter weight 在整个 feature map 扫描过程中保持不变。

因此，weight 可以加载到本地 buffer 中复用，而不是每个 window 重新加载。

最大 `Cin = 512` 时，DWConv3×3 的 weight 大小为：

```text
512 channels × 9 Bytes = 4608 Bytes = 4.5 KB
```

因此可以设计：

```text
9 个 512-Byte weight buffer
```

等价于：

```text
512 channels × 9 kernel positions
```

这样每一层 DWConv3×3 只需要加载一次 weight，之后在所有 `x, y` 位置上反复复用。


## 5. Load 和 compute 的关系

一个 cycle 只能分别加载：

```text
16 Bytes activation
16 Bytes weight
```

因此，填满一个 `3×3 activation window` 需要：

```text
9 cycles
```

但是这一次加载得到的是 16 个 channel 的数据。由于当前只有一个 `3×3 PE array`，所以 16 个 channel 需要分 16 cycles 依次计算：

```text
cycle 0  → channel c+0
cycle 1  → channel c+1
...
cycle 15 → channel c+15
```

也就是说：

```text
load time    = 9 cycles
compute time = 16 cycles
```

使用 ping-pong activation buffer 后，可以在当前 window 计算的 16 cycles 内加载下一个 window 的 9 cycles 数据。

因此在 steady state 下，activation load latency 可以被 compute 完全隐藏，整体吞吐主要由 16-cycle compute 决定。


## 6. 总结

本设计的核心是：

```text
1. Conv1×1 继续使用 HWC layout，以适配 systolic array。
2. DWConv3×3 / Conv3×3 使用一个普通 3×3 PE array。
3. 为了匹配 128-bit HWC 读写宽度，spatial engine 按 16-channel tile 计算。
4. Weight 使用 512 × 9 Bytes 本地 buffer，实现整层复用。
5. Activation 只缓存当前 3×3 window，并采用 ping-pong buffer 隐藏加载延时。
6. Steady state 下，每个 output[y][x] 的 16-channel tile 约需要 16 cycles 完成。
```
设计方略：DWConv3x3 / general Conv3x3 先共用一个普通 3x3 PE array，固定 spatial 位置后沿 channel tile 方向计算，以匹配 HWC layout 和 SRAM word bandwidth。

# 模块实现
## computational unit
端口信号应该为：
9个8bits weight输入，9个8bits activation输入， enable进行一次整个array计算的全局使能信号（input），32bits的输出psum信号，考虑到要要多级pipeline（因为把9个mul结果加起来不能和mul放一起，且加法链长）所以需要一个valid output信号（这个信号其实就把输入enable也通过同样等级数的pipeline，这样就对齐了）

## local buffer设计：
然后实现activation和weight的local buffer。（这两个可以统一设计成参数化的）
写端口：128bits的data in, clear信号重置pointer到buffer起始位置，wr_en写使能
读端口：8bits的data out，配合data valid, 需要有rd_idx(或者叫rd_addr), 以及地址有效信号（或者是读使能信号）
参数化部分：可以调节一128bits为倍数的深度

all_weights_loaded_o现在是整个9个buffer完全写满了后拉高。weights_loaded_o写完一个完整tile后拉高。
```
cycle N:
  写入当前 word group 的第 9 个 kernel position

cycle N 后:
  weights_loaded_o = 1
  表示这个完整 3x3 filter tile 已经可以读

如果这是最后一个 DEPTH word group:
  all_weights_loaded_o = 1
  表示 9 个 buffer 的整个 depth 都写满了

weights_loaded_o 会保持到下一组 weight tile 开始写入时清掉。
all_weights_loaded_o 一旦拉高，会保持到 clear_i。
```