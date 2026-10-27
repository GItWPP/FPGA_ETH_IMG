# FPGA_ETH_IMG · ZU4EV 千兆以太网图像工作台

电脑通过 **PL 千兆以太网 / UDP** 发送图片，**XCZU4EV-SFVC784-2-I** 完成图像处理、HOG＋SVM或Band点阵解码，再经网口返回结果。系统使用PL片上RAM，不需要PS启动程序或DDR。

工程由UART_IMG移植，时钟、RGMII和引脚参考ADC_ETH。原UART_IMG工程独立保留；本版本的综合顶层为 `eth_img_top`，硬件接口与实际运行的上位机均使用以太网。

## 直接运行

1. v1.6传输域与算法域均为125MHz，必须用Vivado Hardware Manager下载本版 `project_eth/build/eth_img.bit`；上位机协议兼容，EXE无需更换。运行包另含已验收的50MHz算法回退固件 `eth_img_algo50.bit`。JTAG配置掉电后需重新下载。
2. 网线连接ADC_ETH所用的 **PL网口**，电脑同网段IPv4为 `192.168.1.18/24`。当前实测“以太网2”协商到1 Gbps。
3. 双击 `tools/dist/ETH_Image_ZU4EV.exe`，无需安装Python。在左侧网络栏填写板卡 **192.168.1.12**、**UDP端口1234**，可点击“检测连接”。
4. 打开 `test_img` 的图片，选择算法并“发送并处理”。默认自动识别图片尺寸，预览支持滚轮缩放、拖拽、1:1和双击适应窗口。
5. Band使用 `test_img/1.png`～`4.png`。“查看0/1”显示数据行，“保存结果”导出标记图、二进制、同步行、CSV及JSON。

默认MAC为 `02:55:49:4D:47:04`。板卡IP、MAC、UDP端口通过顶层参数配置，修改后重新构建。回复发往每个请求自身的源MAC、IP和UDP端口，上位机本地端口自动分配。支持ARP与IPv4/UDP；不实现ICMP，请用上位机“检测连接”或下面的UDP探测命令代替系统ICMP ping。

## 功能范围

| 功能 | FPGA处理 | 输入范围 |
| --- | --- | --- |
| 原图、灰度、反色 | RGB565像素运算 | 宽1～1920，高1～1080 |
| 去噪、边缘 | 3×3彩色均值、中值、Sobel | 同上，上位机组装原始邻域分片 |
| 增强 | Gamma提亮、3×3彩色锐化 | 同上 |
| HOG＋SVM | 梯度、直方图、归一化与495个窗口得分 | 等比例补边到320×240，单尺度64×128全身行人窗口 |
| Band | 暗点检测、同步定位、网格拟合与0/1采样 | 原生16～512 × 16～512，近水平点阵、点距8～32像素 |

HOG框由上位机根据FPGA得分做阈值筛选、NMS和坐标映射，得分不是概率，当前模型为 `7803AC83`。Band位置、位值和标志均由FPGA返回，底部两行同步点不进入数据文本。Band要求每行至少5个可检测点，尚不支持大角度旋转、透视、全零或极稀疏行。

## 视频播放与界面

界面采用左侧控制栏、右侧原始/结果双画面及底部黑底绿字指标区，显示处理FPS、有效吞吐、处理耗时、源FPS、跳帧与重试。左右画面按同一个已完成帧同步更新，播放期间滚轮缩放和拖动位置保留。

1. 点击“打开视频”，选择视频文件，再选择现有图像算法或HOG行人检测。
2. 在“视频播放”中选择处理尺寸和策略，点击“开始播放”。尺寸表示等比例缩放边界，640×360视频选择320×240时实际处理320×180。
3. “实时播放”跳过过期帧保持低延迟；“逐帧处理”保留全部帧，较慢算法会延长播放时长。支持暂停、继续、停止、重新播放和保存当前帧。

30 FPS、6秒本地MP4实板结果，均零重传：

| 模式 | 实际处理/显示尺寸 | 处理FPS |
| --- | --- | --- |
| 原图 | 320×180 | 24.20 |
| 原图 | 640×360 | 30.04 |
| Gamma | 320×180 | 30.08 |
| Sobel | 320×180 | 28.96 |
| HOG行人检测 | 640×360，算法输入320×240 | 5.64 |

高分辨率和复杂算法的帧率受通信与计算共同限制；当前不能按1080p 25/30 FPS全帧回传。HOG仍为单尺度全身行人检测，框由上位机根据FPGA得分绘制。

测试视频为 `test_video/fpga_demo.mp4`，来自本项目测试图片。EXE已包含视频解码依赖，无需另装Python。视频运行中检查协议CRC和返回完整性，原图模式逐字节比较；其他视频算法不在电脑重复计算每帧参考，静态图片保留完整参考校验。设计与完整验证见 [视频处理设计](doc/视频处理设计.md) 和 [验证记录](doc/验证记录.md)。

![视频工作台界面](doc/images/video_workbench.png)

## 实测结果

2026-10-23，XCZU4EV-SFVC784-2-I，Vivado 2024.2，电脑192.168.1.18与PL千兆网口直连。v1.6将算法域从50MHz提升至125MHz，传输域继续125MHz。算法RTL、ROM和XDC与50MHz版哈希完全相同，未改变算法结果或流水级。

| 同板5次中位指标 | 算法50MHz | 算法125MHz | 加速 |
| --- | --- | --- | --- |
| HOG RUN命令 | 157.7 ms | 63.9 ms | 2.47× |
| Band RUN命令 | 114.9 ms | 46.8 ms | 2.45× |
| HOG完整网络事务 | 267.8 ms | 169.1 ms | 1.58× |
| Band完整网络事务 | 483.1 ms | 399.2 ms | 1.21× |
| 640×360 gamma完整网络事务 | 48.9 ms | 27.4 ms | 1.79× |
| 640×360 mean完整网络事务 | 250.9 ms | 112.6 ms | 2.23× |
| 640×360 median完整网络事务 | 748.9 ms | 311.0 ms | 2.41× |
| 640×360 sobel完整网络事务 | 251.0 ms | 112.6 ms | 2.23× |
| 640×360 sharpen完整网络事务 | 204.9 ms | 94.2 ms | 2.17× |

RUN命令包括该命令的UDP往返；完整网络事务还包含上传、应答及回读。编码、独立参考计算和显示在网络计时之外，所有结果逐字节或逐项一致，均零重传。计算提升接近2.5倍，整图速度还受传输与上位机影响。

| 验收 | 结果 |
| --- | --- |
| Python / RTL | 107项软件测试、18项RTL自检通过 |
| GMII与反压 | 199项整机事务、197项窗口回复、197项反压应答；另通过非整数时钟比和执行中复位 |
| HOG | 当前10张图片及2个合成帧，共5940个得分逐项一致 |
| Band及图像算法 | 4张Band图片、合成/异常/重试及24次八算法传输与参考一致 |
| 实板故障注入 | 64包窗口主动丢请求、丢最早回包、乱序均恢复，130KiB完整结果一致 |
| EXE | Band、HOG、Gamma、1080p原图、视频原图/视频HOG及播放控制均通过 |

1920×1080原图4,147,200字节，五次中位0.0758秒、**437.5 Mbps**。EXE本次398.2 Mbps、后台总计0.130秒。有效Mbps按一幅图像字节数除以完整收发时间计算，双向应用负载合计875.1 Mbps；物理链路为全双工1Gbps，主机调度会影响不同轮次。原图已走高速旁路，因此算法提频对原图收益有限。

普通图像默认32包、最多64包窗口。请求/应答/完成确认通过异步FIFO，数据通过双时钟RAM；64个逻辑缓存槽加1个独立暂存物理槽，成功后原子换槽，错误请求不会覆盖旧重发结果。HOG/Band继续采用独立命令事务。

资源：8255 LUT、7748寄存器、103/128 BRAM、8/48 UltraRAM、5 DSP。内部建立/保持裕量1.470/0.007ns，DRC无错误、CDC无critical项，总线偏斜检查通过。RGMII外部I/O delay仍需依据PHY/PCB参数完成板级签核。

默认 `tools/build.ps1 -AlgorithmMHz 125` 输出project_eth/build；`-AlgorithmMHz 50`输出project_eth/build_50mhz。已验证的50MHz固件及旧XCI/构建记录保留在后者，运行包附eth_img_algo50.bit，可直接在Hardware Manager回退。

设计与数据：[算法125MHz提频](doc/算法125MHz提频.md)、[验证记录](doc/验证记录.md)。跨时钟结构：[设计说明](doc/高速传输与算法跨时钟解耦.md)；历史：[v1.5验证](doc/legacy_ethernet/验证记录_v1.5.0.md)。

## 源码运行与构建

以下命令均在本目录执行：

```powershell
python -m pip install -r tools/requirements-video.txt
python tools/eth_image_gui.py
python tools/eth_image.py ping --host 192.168.1.12 --port 1234
python tools/eth_image.py send test_img/test1.png --mode gamma --output received.png
.\tools\build.ps1
```

使用Vivado **2024.2**，独立工程为 `project_eth/eth_img.xpr`。可用 `-VivadoBin` 覆盖安装位置。脚本仅在本工程XPR不存在时创建，不使用 `create_project -force`；会增补RTL、生成Clocking Wizard，并检查预期综合层级。报告、检查点、bitstream在 `project_eth/build`。模型ROM和 `project_eth/ip/clk_wiz_eth/clk_wiz_eth.xci`须保留。

```powershell
python -m pip install -r tools/requirements-dev.txt
python tools/verify_repository.py
python tools/eth_image.py selftest
python tools/check_rtl_style.py
.\sim\run_all_sim.ps1
```

完整仿真包含原有9个算法/协议自检及异步邮箱、官方RGMII DDR模型、GMII端到端、64槽队列、快速组包器、64包窗口突发、流水线反压和UltraRAM字节使能及异步算法复位9个网络/存储自检。参考向量每次重新生成，独立检查Ethernet FCS、IP/UDP checksum与期望应用结果。

```powershell
vivado -mode batch -source tools/hardware.tcl -tclargs program
python tools/board_eth_band_test.py
python tools/board_eth_hog_test.py --user-images
python tools/board_eth_window_test.py
python tools/generate_video_fixture.py
python tools/board_video_test.py
python tools/board_host_benchmark.py
python tools/board_eth_throughput.py --sweep --repeat 3
.\tools\package_exe.ps1
.\tools\verify_exe.ps1
python tools/package_release.py
```

下载脚本仅选择ZU4器件。运行 `package_exe.ps1` 重新生成 `ETH_Image_ZU4EV.exe`，打包环境保存在本工程。历史命名 `uart_image.py` 保留共用包格式、像素参考与原客户端测试；实际GUI、`run_gui.ps1`、exe均使用 `eth_image_gui.py` 和独立UDP客户端 `eth_image.py`。

## 目录

```text
rtl/                 原有独立算法、命令、HOG/Band及新顶层
rtl/ethernet/        MAC、IPv4、UDP、ARP及UltraScale+ RGMII
rtl/transport/       整包校验、64槽RX/8槽TX、原子结果缓存、异步算法桥和快速组包
sim/                 18个自检、向量及运行脚本
project_eth/         独立ZU4EV工程，build/为生成输出
tools/               UDP上位机、视频流水/仪表布局、exe打包及板卡回归
test_img/            当前10张测试图片及分组清单
test_video/          由测试图片生成的MP4、来源及生成脚本说明
doc/                 当前方案、协议、验证与历史资料
eth_img.xdc          板卡管脚、时钟及I/O标准
eth_cdc.xdc          实现阶段的具体CDC路径约束
```

接口保留RX、传输、算法、TX四个时钟端口，当前均为125MHz，TX保留板卡相移；算法可回退50MHz。输入UDP包完整校验后才提交，回复完整缓存后才交给MAC；地址按请求绑定，未消费的队列槽及未连续确认的窗口结果禁止覆盖。详细连接、端口和握手见 [移植方案](doc/ZU4EV千兆以太网移植方案.md)，命令见 [应用层协议](doc/应用层协议.md)，验收见 [验证记录](doc/验证记录.md)。
