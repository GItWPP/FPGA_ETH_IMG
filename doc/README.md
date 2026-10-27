# 当前资料

- [算法125MHz提频](算法125MHz提频.md)：默认125MHz算法时钟、50MHz回退配置、同板计算与整图事务基准。

- [高速传输与算法跨时钟解耦](高速传输与算法跨时钟解耦.md)：125MHz传输、50MHz算法、异步描述符FIFO及缓存原子提交。

- [ZU4EV千兆以太网移植方案](ZU4EV千兆以太网移植方案.md)：器件、时钟、连接、端口、整包握手及验证顺序。
- [应用层协议](应用层协议.md)：图像、HOG与Band命令；一个完整应用包对应一个UDP数据报。
- [滑动窗口传输设计](滑动窗口传输设计.md)：8包窗口、结果回放、异步整包队列、原图快速通道及验证要求。
- [视频处理设计](视频处理设计.md)：视频文件解码、帧配对、低延迟播放、暂停/停止及实板验证。
- [验证记录](验证记录.md)：仿真、实现、板卡结果、时序范围及速度。

`legacy_uart/`保存从UART_IMG继承的历史设计与验收，其中AX7Z020B、J20、COM11、1.5Mbps和旧文件名属于原工程，不是当前ZU4EV的接线或运行参数。当前以根README、`eth_img.xdc`及移植方案为准。

以太网协议结构来自用户提供的ADC_ETH。迁移时保留协议层功能，按工程风格拆分状态、计数器与数据寄存器，并修正无以太网补零的UDP包末字节校验提交时序。RGMII使用UltraScale+ IDDRE1/ODDRE1，整包缓存使用官方XPM_MEMORY_SDPRAM。

原语和双时钟存储器接口依据AMD官方资料：[UltraScale SelectIO UG571](https://www.amd.com/content/dam/xilinx/support/documents/user_guides/ug571-ultrascale-selectio.pdf)、[XPM_MEMORY_SDPRAM](https://docs.amd.com/r/2024.2-English/ug1353-versal-architecture-ai-libraries/XPM_MEMORY_SDPRAM)。管脚来自本地ADC_ETH约束，没有从通用器件文档推测板卡管脚或板级延迟。

- [流水线与64包窗口设计](流水线与64包窗口设计.md)：双包解析、独立应答FIFO、缓存busy保护、Band UltraRAM迁移及64包能力协商。

- [上位机快速收发与图像转换](上位机快速收发与图像转换.md)：严格UDP整包校验、非阻塞窗口、期限堆及静态/视频共用RGB565转换。
