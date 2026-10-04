# 原论文 FPGA 数据复现

本目录独立复现 vPIFO SIGCOMM 2024 论文 Figures 9--11、19--24 的 FPGA
数据，不使用异构控制面或 Stage25--28 优化。

## 论文配置

- FPGA：Xilinx Alveo U200，`xcu200-fsgd2104-2-e`；
- 论文工具：Vivado 2018.3；本机可用工具：Vivado 2019.2；
- rank/PTW：16 bit；
- metadata/MTW：32 bit；
- counter/CTW：10 bit（公开 RTL 默认值）；
- TaskFIFO：8（公开 RTL 默认值）；
- top：原版 `PIFO_SRAM_TOP`，不增加三层调度 wrapper；
- 资源同时记录 post-synthesis 和 post-route；频率以 post-route 最差内部
  reg-to-reg setup path 为准。实测 post-synthesis 的频率估计明显过于乐观，不能
  用来复现论文频率。

本轮三个 N=21 点为：

| BMW 配置 | 每 instance 容量 | N=21 是否为论文原始采样点 |
|---|---:|---|
| M=2, L=10 | 2,046 | 是 |
| M=4, L=6 | 5,460 | 否；论文采样 N=2/7/13/25 |
| M=8, L=4 | 4,680 | 否；论文采样 N=2/5/9/17/33 |

论文原始 Excel 中 M2/L10/N21 为：`clock=8.1 ns`、`frequency=123.4568
MHz`、`LUT=174243`、`LUT%=14.74`、`LUTRAM=148880`、`LUTRAM%=25.16`。
另外两个 N=21 结果必须标记为使用论文 RTL 参数新增的中间点，不能称为论文
已发布数据。

## 源码隔离

- `source_03b4947/` 是 GitHub 提交 `03b4947` 中 `_2/_4/_8` 目录的逐字节
  快照；创建后已通过 Git blob hash 逐文件检查。
- `source_paper_consistent/` 仅在每套源码的 `PIFO_SRAM.sv` 和
  `PIFO_SRAM_TOP.sv` 中修复 SRAM 地址表达式。其余文件与 `03b4947` 完全相同。

公开源码写成：

```systemverilog
$clog2(TREE_NUM + LEVEL - 1 / LEVEL) + TREE_SIZE_BITS
```

其中 `1 / LEVEL` 为零，会产生远大于论文 Excel 的 SRAM。论文 Excel 的 LUTRAM
阶梯与 rotating placement 的 `ceil(TREE_NUM/LEVEL)` 分组和二进制深度完全吻合，
说明论文综合使用的实际版本不含这个优先级错误。因此默认使用
`paper_consistent`；`github_verbatim` 模式保留用于公开源码差异审计。

## 运行

示例：

```powershell
D:\Xilinx_U200\Vivado\2019.2\bin\vivado.bat -mode batch `
  -source synth_original_paper_point.tcl -tclargs `
  2 10 21 8.1 paper_m2_l10_n21 paper_consistent Default
```

参数依次为 BMW order、BMW level、instance 数、时钟周期、run tag、源码模式和
synthesis directive。结果保存在 `runs/<run_tag>/reports/`。

完整实现示例：

```powershell
D:\Xilinx_U200\Vivado\2019.2\bin\vivado.bat -mode batch `
  -source implement_original_paper_point.tcl -tclargs `
  runs/paper_m2_l10_n21/paper_m2_l10_n21_ooc_synth.dcp `
  paper_m2_l10_n21_postroute default
```

`default` 流程为 `opt_design`、`place_design`、`route_design`，不额外运行
`phys_opt_design`，以免把异构版本后期使用的 aggressive 实现优化搬到论文基线。
由于公开仓库没有作者的 Vivado project/run strategy，这里将 Vivado 默认流程作为
最少假设的复现口径。

## 生成的报告

运行结果保存在 `runs/<run_tag>/reports/`，包括资源和时序摘要。该目录由 Git 忽略；
可使用上述脚本重新生成报告。
