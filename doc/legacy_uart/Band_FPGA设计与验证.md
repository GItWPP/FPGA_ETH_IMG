# 固定点阵 Band FPGA 解码

## 目标与边界

FPGA 接收原始灰度图，独立完成暗点提取、数据带定位、逐行网格拟合和二进制判决。上位机只转换灰度格式、上传、绘制 FPGA 返回的采样点和导出数据。底部两行连续点用于同步，不计入数据二进制。

首版输入为原生尺寸 16～512 × 16～512 的 gray8 图片，不自动缩小；横向点距支持 8～32 像素，针对直径约3～6像素、局部对比度足够的暗点。处理一个最长的近水平数据带，至少 4 行、每行至少 5 个可检测暗点，最多 64 行；候选行间隔超过24像素划为另一band。同步行必须连续且每行至少 8 点。大角度旋转、透视、全零/极稀疏行及多 band 同时输出属于后续扩展；当前版本不能用于保证包含这些情况的完整码流恢复。边缘截断点保留并标记，不推测图像外空白位。

## 时钟、接口和时序

- 时钟 `sys_clk` 为 50 MHz，`sys_rst_n` 低有效；复用已有 UART 1.5 Mbps、8N1、CRC16 分包协议，无新外部引脚或时钟域。
- `frame_wr_en/addr/data` 在每个时钟沿写入灰度帧；行跨度固定 512，控制器将紧凑上传字节映射到二维地址。
- `start_valid && start_ready` 接受一次解码请求；先扫描整帧，再根据候选点完成定位；处理期间禁止上传。
- 帧 RAM 同步读取一拍，扫描器按“请求地址→等待→取数”推进，使用有效状态屏蔽未写数据。
- `dot_valid` 是候选点事件，携带整数像素坐标及局部对比度；存储器须在 `scan_done_flag` 后再提交最后一行。
- `done_flag` 为单拍完成事件；结果计数、状态和结果 RAM 保持到下一次运行。协议控制器完整写好共享应答缓存后再发出应答。

`band_decode_top`端口约定如下，所有信号均处于`sys_clk`域：

| 接口 | 方向/位宽 | 时序与功能 |
| --- | --- | --- |
| sys_clk / sys_rst_n | 输入1/1 | 50MHz，低有效复位 |
| frame_wr_en / addr / data | 输入1/18/8 | 写入一像素，地址为y×512+x；运行期间不得写入 |
| image_width / image_height | 输入10/10 | 本帧宽高，START前设置，保持到done |
| start_valid / start_ready | 输入1/输出1 | 同时为1时启动一次完整帧解码 |
| done_flag | 输出1 | 一拍完成标志，结果和状态随之有效 |
| result_count / result_rows | 输出16/8 | 采样记录数/总行数，包含两行同步点 |
| pitch_q8 / result_status | 输出16/8 | 点距定点数/算法状态 |
| detected_dots | 输出16 | 候选点数；缓存超限时饱和并返回溢出状态 |
| result_rd_addr / result_rd_data | 输入12/输出32 | 结果RAM同步读一拍，完成后才能读取 |

## 模块与算法

`band_command_top` 封装独立协议控制器和 `band_decode_top`；后者连接灰度 BRAM、`band_dot_detect`、`band_grid_track` 以及结果 RAM。

```text
img_command_top
└─ band_command_top
   ├─ band_uart_ctrl
   └─ band_decode_top
      ├─ img_block_buffer（独立灰度帧实例）
      ├─ band_dot_detect
      ├─ band_row_store
      ├─ band_grid_track
      │  └─ band_unsigned_div
      └─ 采样结果BRAM
```

1. 暗点检测：以中心周围 8 个采样点平均灰度减去中心灰度，默认对比度门限 35；再做 9×9 最小值抑制，避免平底圆斑产生重复候选点。并列最小值保留扫描顺序最早者，越界邻点不参与最小值比较。
2. 行与 band 定位：按 y 坐标聚合候选点，间隔超过 5 像素另起一行；过滤少于 5 点的行，再按行间隔 24 像素划分 band，选行数最多者。
3. 同步定位：排除偏离行均值超过 3 像素的点，以底部两行端点跨度/点间隔数估计共享点距，采用 Q8 定点数；通过同步网格覆盖率验证定位。
4. 逐行相位：统计候选点对共享点距取模后的相位直方图，以主峰附近的残差均值微调相位，适应各行独立的水平偏移。
5. 判决：网格点附近 3 像素内有候选点判 1，否则判 0；返回原图采样坐标、行号、同步标志、边界标志及低置信标志。

设计资源采用 512×512×8 bit 灰度帧、有限长候选点列表及结果列表，不缓存 RGB 彩色帧。除法采用有界多拍迭代；存储溢出或同步失败必须返回非零状态，不输出为有效解码。

## 协议

命令 `0x20` START（宽高各 u16），`0x21` DATA（最多 1024 字节 gray8），`0x22` RUN，`0x23` READ（offset/count 各 u16，最多 256 个 u32 结果），`0x2f` INFO。保留原协议会话、顺序、最近成功包重发及跨算法缓存失效规则。

RUN 返回 16 字节：`BND1`、结果数 u16、总行数 u8、状态 u8、点距 Q8 u16、宽 u16、高 u16、候选点数 u16。状态 0 成功、1 无有效 band、2 同步失败、3 缓存溢出、4 点距超范围、5 行定位失败。

结果 u32：`[8:0] x`、`[17:9] y`、`[18] bit`、`[19] sync`、`[20] partial`、`[21] low_confidence`、`[27:22] row`，其余保留为零。数据按从上到下、每行从左到右排列；保留每行可见长度，不声称已恢复原始逻辑列号。

## 验证记录

2026-10-21已完成以下验证。彩色 debug 图仅用于解码后的独立标记对照，不参与 FPGA 输入或定位。

### 原图与板卡结果

输入`test_img/1.png`，512×512。FPGA返回21行、637个采样位置，其中底部2行为同步行；数据部分19行、575个可见位、274个1。各行可见长度30或31，不强行补齐边缘丢失数据。点距Q8=4339，即16.94921875像素。

637条FPGA采样记录（包含坐标、位值和标志）与整数参考逐项相同。与用户`5_debug.png`中的彩色标记对照：633个有标记位置全部一致，4个位置无可对照标记。该对照不等于真实误码率或原始码流100%正确，当前没有原始二进制真值和纠错校验。10个边界采样位置已在CSV中标记。

1.5Mbps、COM11实测：原图上传、FPGA处理及结果读取约2.77秒；RUN命令往返约0.117秒。RTL核心5669353个50MHz时钟，约0.1134秒。返回637个u32记录共2548字节，上传灰度数据262144字节。EXE实测整次约2.743秒、自动通信重试0次。

实板还通过带噪声和逐行水平偏移的已知码流合成图、降低45灰度值的原图、空白帧拒绝、点列表溢出拒绝，以及DATA/RUN/READ重复包、跨算法错误请求缓存保持和START会话失效检查。测试代码`tools/board_band_test.py`，结果`tools/board_results_band/board_band_test.json`。

### 仿真、实现与回归

- 60项Python测试通过，其中11项覆盖Band已知位、噪声、行偏移、帧尺寸、溢出、协议结构、原图标记对照、GUI二进制窗口、导出和模式切换。
- 全部9个RTL自检通过：原有7个测试及`tb_band_uart_ctrl`、`tb_band_decode_top`。前者20个协议事务；后者逐项检查原图637条、合成图121条、降低亮度原图637条及空白帧状态。
- Vivado2024.2综合、布局布线与bitstream通过，器件xc7z020clg400-2。建立裕量5.952ns、保持裕量0.036ns；4564 LUT、3414寄存器、124.5/140 BRAM（88.93%）、5 DSP。DRC为0 Error，114项普通Warning；构建无Critical Warning。当前片上存储余量有限，后续更大Band图像需重新规划缓存。
- 用户已有`project_uart/project_uart.xpr`只增补源文件引用，未重建工程。当前标准bitstream为`project_uart/build/uart_img.bit`，与已验收候选文件逐字节相同。旧版bitstream保存在`tools/backups/before_band/uart_img.bit`，旧报告保存在其`build_reports`子目录。
- 实板回归4帧HOG、1980个窗口得分及原有八算法共24次传输全部通过；HOG模型仍为7803AC83。报告`tools/board_results_band/legacy_regression/board_hog_test.json`。
- Windows x64单文件EXE的实际GUI工作线程通过Band原图、HOG图片以及16次原有图像算法传输，另有21项缩放/拖拽/适应窗口检查。EXE中的637条Band记录再次与参考逐项相同。报告为`exe_band_test.json`、`exe_hog_test.json`和`exe_legacy_test.json`，均位于`tools/board_results_band`。

### 使用和复现

1. 双击`tools/dist/UART_Image_Band.exe`，选择COM11、1500000，打开`test_img/1.png`，选择“Band 点阵二进制解码”，点击“发送并处理”。
2. 绿圈表示1、红叉表示0、青圈表示同步点，黄色短线表示边界位置。点击“查看0/1”显示已排除同步行的二进制。滚轮缩放、拖动和双击适应仅改变预览。
3. 点击“导出结果”，选择PNG或BMP路径；同时写出`_bits.txt`（仅数据）、`_sync.txt`、`_cells.csv`和`_report.json`。文本逐行保存；若要判断边界位是否可用，应同时查看CSV的partial/low_confidence字段。
4. 单独的Band参考和仿真向量使用NumPy，可安装`tools/requirements-band-test.txt`；运行整个项目的全部自检需安装`tools/requirements-dev.txt`。日常EXE运行不需要NumPy或Python，Band检测与判决参考模型没有打包进上位机。

在工程根目录运行：

```powershell
python tools/uart_image.py selftest
.\sim\run_sim.ps1 -Python python
python tools/check_rtl_style.py
python tools/board_band_test.py --port COM11
.\tools\package_exe.ps1
```

若要重新构建硬件，运行`tools/build.ps1`，使用Vivado2024.2。本站已有hw_server版本2019.2，本次由匹配的2019.2 Hardware Manager将2024.2生成的bitstream下载到Digilent 210512180081上的xc7z020_1，成功确认启动完成；未写入非易失存储。

当前版本SHA256：

- bitstream：`7ECB3FD30D92B4E2AB440F6787E03C1B4B4775C9CB44514FE50F969F65FD5A0F`
- EXE：`39D4CD81F7861AA808F3D434FE06519145EFC36FDFF613F41350B9C8E6E11813`

完整发布文件与源码校验清单为`tools/band_release_manifest.json`。
