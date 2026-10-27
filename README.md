# FPGA_ETH_IMG · ZU4EV 千兆以太网图像 / 视频工作台

[下载 v1.7.0（EXE、固件、运行包与源码包）](https://github.com/GItWPP/FPGA_ETH_IMG/releases/tag/v1.7.0) · [验证记录](doc/验证记录.md)

电脑经PL千兆以太网发送图片或视频帧，XCZU4EV-SFVC784-2-I完成图像处理、HOG＋SVM或Band点阵解码，结果回传到双画面工作台。工程使用片上RAM，无需PS启动程序或DDR。

v1.7新增 **1280×720 / 25 FPS 流式Sobel视频**。FPGA执行RGB565亮度转换、两行缓存、3×3窗口和流水线Sobel，回传GRAY8。上位机负责视频解码、打包与显示。完整逐帧结果、重试和EXE验收见[验证记录](doc/验证记录.md)；本轮没有验收30 FPS。

## 直接运行

1. 使用Vivado Hardware Manager下载本版 `project_eth/build/eth_img.bit`，双击本版 `tools/dist/ETH_Image_ZU4EV.exe`。视频流式Sobel需要配套的新EXE和bit。JTAG配置掉电后重新下载。
2. 网线连接ADC_ETH使用的PL千兆网口。电脑IPv4为192.168.1.18/24，板卡IP为192.168.1.12、UDP端口1234；选择对应电脑网卡，可点击“检测连接”。
3. 图片：打开 `test_img` 中图片，选择算法后发送。支持自动尺寸、滚轮缩放、拖动、1:1及双击适应窗口。
4. 720p25视频：打开 `test_video/fpga_demo_25.mp4` 或本地视频，选择 **Sobel 边缘检测 → 原视频尺寸 → 逐帧处理（不跳帧） → 开始播放**。支持暂停、继续、停止、重播、缩放与保存当前帧。
5. Band使用 `test_img/1.png`～`4.png`，支持查看/导出0/1、同步行、CSV、JSON和标记图。

EXE包含视频解码依赖与Windows原生UDP收发模块，不需要Python或编译器。界面左侧设置、右侧同帧原图与结果、底部显示处理FPS、有效吞吐、耗时、跳帧及重试。

## 算法与数据流

| 入口 | FPGA功能 | 范围 |
| --- | --- | --- |
| 静态图片 | 原图、灰度、反色、Gamma、彩色3×3均值/中值/锐化、Sobel | 宽1～1920，高1～1080 |
| 视频Sobel | 两行缓存与流式Sobel，GRAY8回传 | 同上；本轮性能验收1280×720 / 25 FPS |
| 其他视频模式 | 复用既有图像算法或HOG通道 | 速度由各算法决定 |
| HOG＋SVM | 特征、归一化及495个窗口得分 | 算法输入320×240，单尺度64×128全身行人窗口 |
| Band | 暗点、同步定位、网格拟合及二进制采样 | 原生16～512 × 16～512，点距8～32像素 |

视频Sobel上传原始RGB565，仅额外复制右边界一列和下边界一行；720p每帧上传1,847,202字节、回传921,600字节。25 FPS上下行应用图像负载约369.44/184.32 Mbps，均不含协议开销。传输和算法域125MHz，GMII原有相移保持。

新协议0x40/41/42、64包窗口沿用整包CRC及原子应答缓存，重复DATA不会再次推进算法。解码打包队列限2帧，与收发重叠；Windows批量UDP循环释放Python运行锁，避免逐包收发与GUI争用。原Python实现作为兼容回退。

原静态图像默认32包窗口，最多64包；原0x01～0x24协议保留。HOG/Band继续独立模块与命令。各算法模块分别封装，流式Sobel入口为 `rtl/img_sobel_stream_top.v`，协议控制位于 `rtl/transport/img_sobel_stream_ctrl.v`。

HOG得分不是概率，模型ID为7803AC83；上位机根据得分进行阈值筛选、NMS和坐标映射。Band底部两行同步点不计入数据，要求每行至少5个可检测点，尚不支持大角度旋转、透视、全零或极稀疏行。

“实时播放”允许跳过过期源帧；“逐帧处理”处理全部帧。其他算法与其他分辨率的帧率应分别实测，25 FPS结论针对本轮720p Sobel工作负载。

## 源码与构建

独立Vivado项目为 `project_eth/eth_img.xpr`，综合顶层 `eth_img_top`。RTL在rtl，仿真在sim，文档在doc，上位机和工具在tools。引脚、RGMII参考ADC_ETH，原UART_IMG工程保留。

```powershell
python -m pip install -r tools/requirements-video.txt
python tools/eth_image_gui.py
python tools/eth_image.py ping --host 192.168.1.12 --port 1234
.\tools\build.ps1
.\sim\run_all_sim.ps1
python -m unittest discover -s tools -p "test_*.py"
```

Windows原生收发源码、预编译DLL与重建脚本在 `tools/native`。可使用64位GCC运行 `tools/native/build.ps1` 重建，再运行 `tools/package_exe.ps1`。源码包保留已验证DLL；缺少DLL时回退Python收发，性能会下降。原生模块只负责UDP协议，不执行图像算法。

实板验收：`python tools/board_stream_video_test.py --input test_video/test.mp4`，输入要求1280×720、25 FPS。也可指定附带的 `test_video/fpga_demo_25.mp4`。报告位于tools/board_results_stream。打包前 `tools/package_release.py` 检查源码/固件哈希、20项RTL自检、软件与实板结果及EXE版本，防止使用旧报告标记新构建。

默认 `tools/build.ps1 -AlgorithmMHz 125` 输出project_eth/build。历史50MHz回退固件保留在project_eth/build_50mhz，运行包附eth_img_algo50.bit；该旧固件不支持新视频Sobel协议。

资源、时序、校验与完整视频实测以[验证记录](doc/验证记录.md)为准。RGMII外部I/O delay仍需依据PHY/PCB参数完成板级签核。

设计：[720p25流式Sobel](doc/720p25流式Sobel设计.md)、[跨时钟解耦](doc/高速传输与算法跨时钟解耦.md)。历史性能：[v1.6验证](doc/legacy_ethernet/验证记录_v1.6.0.md)。
