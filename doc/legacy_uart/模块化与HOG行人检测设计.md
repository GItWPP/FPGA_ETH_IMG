# 模块化处理与单尺度HOG行人检测

目标：每种算法独立封装，在原有八模式、自动尺寸和交互界面之上增加320×240单尺度HOG＋线性SVM行人检测。

## 层次与职责

```text
uart_img_top
├─ UART/包协议/接收及结果缓存
├─ img_command_top                命令分发、共享端口与应答仲裁
│  ├─ img_ctrl                    原有八模式会话
│  └─ hog_uart_ctrl               HOG帧上传、启动、得分读取
└─ img_process_top                处理系统顶层，仅连接子模块
   ├─ img_pixel_proc              八模式选择与valid/ready仲裁
   │  ├─ img_copy_top
   │  ├─ img_gray_top ─ img_rgb565_luma
   │  ├─ img_invert_top
   │  ├─ img_mean_top
   │  ├─ img_median_top ─ img_sort9
   │  ├─ img_sobel_top ─ img_rgb565_luma
   │  ├─ img_gamma_top
   │  └─ img_sharpen_top
   └─ hog_detect_top
      ├─ 灰度帧缓存
      ├─ hog_cell_hist_top ─ hog_gradient
      ├─ hog_block_norm_top ─ hog_unsigned_div
      ├─ 特征缓存
      ├─ hog_linear_svm_top ─ 权重ROM
      └─ 得分缓存
```

所有RTL模块各自独立文件。复用公共转换/排序模块，不在处理顶层混写算法公式。HOG与原有处理共享包接收和应答链路；成功请求统一使另一路旧重发缓存失效，错误请求不破坏最近成功缓存。

## 时钟、端口及波形约定

全部处理为sys_clk=50 MHz、低有效sys_rst_n；UART保持1.5 Mbps / 8N1，无新增外部引脚和时钟域。普通控制/数据寄存器按技能采用异步复位；直接驱动BRAM地址、写使能和RAM读出的控制使用同步复位。

|接口|方向|宽度|含义|
|---|---|---|---|
|in_data|算法输入|16|RGB565单像素|
|window_data|邻域算法输入|144|按行排列的九个RGB565，最低16位为左上|
|in_valid/in_ready|输入/输出|1|二者同为1的上升沿接收|
|out_data|算法输出|16|处理后RGB565|
|out_valid/out_ready|输出/输入|1|反压时数据与有效保持|
|HOG frame_wr_addr/data/en|HOG输入|17/8/1|320×240灰度帧写入|
|HOG start_valid/start_ready|输入/输出|1|帧计算启动握手|
|HOG done_flag|HOG输出|1|全部窗口得分已存储的单拍完成信号|
|HOG score_rd_addr/data|输入/输出|9/32|同步读取495个窗口得分|

img_pixel_proc仅允许一个未完成事务，锁存该事务模式；在旧结果被接收的同一拍可接收新事务。各算法有自己的流水/状态和输出保持，模式变化不能切换正在等待接收的结果。

HOG顶层时序：IDLE（上传灰度）→ 直方图清零/梯度累计 → block归一化 → 495窗口SVM → done_flag → IDLE。上传与计算互斥，计算期间缓存保持。所有RAM读经WAIT/GET与同步读延迟对齐。

## HOG首版定义

- 输入固定320×240灰度，行优先；显示原图可继续为1920×1080以内任意尺寸，由上位机等比例缩放/补边并映射检测框。
- 窗口64×128，cell为8×8，block为2×2 cell，block步长1 cell，窗口步长8像素。共33×15=495个窗口，每窗7×15×36=3780维特征。
- 使用中心差分的有符号Gx/Gy，边界复制；幅值为abs(Gx)+abs(Gy)。九个无符号方向区间，使用整数斜率比较进行方向量化，像素只投票到所在cell/方向。
- block特征用L1定点归一化：floor(hist×1024/(四cell各方向总和+1))。这是一版明确约定的硬件HOG，不声称与OpenCV的插值/L2-Hys描述子逐位相同。
- 线性SVM与该定点特征共同训练，导出量化权重和偏置。模型来源、样本拆分、定点量化前后验证结果写入模型清单；不使用随机或未训练权重冒充行人模型。
- FPGA计算每个窗口得分，上位机做阈值筛选、NMS和绘框。得分不是概率。首版为单类别、单尺度、大尺寸直立行人原型，检测质量与计算正确性分别验证。

## 扩展协议

原有01..04和八模式数据格式不变。新命令保留独立会话，不挤占八位图像模式位图：

- 1F INFO：返回HOG1、320/240、64/128、步长、特征版本和模型标识。
- 10 START：seq=0、空负载，建立固定灰度帧会话。
- 11 DATA：seq递增，最多1024灰度字节，成功应答为空；整帧76800字节。
- 12 RUN：整帧完整后启动计算，完成应答含窗口数495。
- 13 READ：负载为offset:u16,count:u16，每次1..256个窗口；应答为count个有符号32位定点得分。

新旧START成功后使另一路图像会话失效，PING不终止会话。最近成功重发、错误不破坏缓存、CRC/超时机制沿用现有规则。RUN由上位机使用较长等待时间。

## 验证顺序

先完成八模式模块化并通过原有穷举、邻域、UART和1080p回归；再验证梯度方向边界、直方图、除法、block特征、SVM与完整495得分，使用独立软件整数参考。检查BRAM推断和布局布线时序后下载本板，并逐字节比较实际得分；同时使用训练集外的人物/背景图片评估检测效果，最后打包EXE。

## 文件与算法接口

|算法顶层|输入|子模块|输出/职责|
|---|---|---|---|
|img_copy_top|in_data[15:0]|无|原图RGB565|
|img_gray_top|in_data[15:0]|img_rgb565_luma|灰度RGB565|
|img_invert_top|in_data[15:0]|无|反色RGB565|
|img_mean_top|window_data[143:0]|无|九像素原生RGB分量均值|
|img_median_top|window_data[143:0]|img_sort9|逐颜色分量中值|
|img_sobel_top|window_data[143:0]|img_rgb565_luma|灰度梯度边缘|
|img_gamma_top|in_data[15:0]|无|Gamma=0.5查表提亮|
|img_sharpen_top|window_data[143:0]|无|五点彩色锐化及饱和|
|hog_detect_top|灰度帧写口和start握手|hog_cell_hist_top、hog_block_norm_top、hog_linear_svm_top、hog_ram|同步读取495个有符号得分|

普通算法通用约定：输入握手时锁存全部输入，后续计算不依赖上游继续保持；out_valid保持到out_ready为1，等待期间out_data稳定。复位清除有效状态。3×3窗口顺序为左上到右下，最低16位为左上，中心在[79:64]；边界复制由原有上位机分片协议提供。

## 继续添加算法

1. 在rtl中新建`img_<算法>_top.v`，按技能保留中文模块头和分区。单像素/九像素算法沿用上表接口；内部复杂计算继续封装子模块。
2. 在`img_pixel_proc`增加实例和模式路由，顶层不放算法公式。当前三位模式及PING八位能力图已使用完；第九种普通像素算法需同步扩展模式位宽与能力查询/协议版本，不能直接挪用已有模式编号。
3. 帧级算法可参照HOG采用独立处理顶层和独立命令控制器，接入`img_process_top`及`img_command_top`。先检查资源、会话互斥、结果RAM仲裁和最近成功应答的重发语义。
4. 在sim中增加独立参考、自检及反压/复位覆盖，在tools中补充上位机数据准备和结果显示。
5. 运行`tools/sync_project_sources.py`同步用户工程文件引用，保留现有工程设置；仿真通过后执行综合/实现和实板验收。

HOG内部边界：`hog_gradient`为组合算术；`hog_cell_hist_top`完成方向投票；`hog_unsigned_div`提供26拍可反压除法；`hog_block_norm_top`生成Q10特征；`hog_linear_svm_top`乘加并饱和32位得分；`hog_svm_model`只保存训练后ROM、偏置和模型ID。替换分类器或归一化策略时须同时更改软件参考、训练特征版本和INFO版本。

## 模型重训练

训练环境与上位机环境分开：`tools/requirements-training.txt`记录本次训练版本；EXE只打包Pillow、pyserial、整数参考与常量模型，不依赖numpy或scikit-learn。

```powershell
python -m pip install -r tools/requirements-training.txt
python tools/archive_hog_baseline.py
python tools/download_hog_dataset.py --all
python tools/train_hog_hnm.py --rounds 3
python tools/verify_hog_quantization.py
python tools/promote_hog_hnm.py
```

数据来自公开INRIA Person镜像，工具使用系统可信证书验证HTTPS、固定镜像revision并保存每张图片SHA256。模型清单位于`doc/hog_model_manifest.json`。训练工具将同一图像编号的镜像/裁剪变体放在同一数据分组，按组拆分训练/验证；采用与FPGA完全相同的方向量化、幅值与L1整数归一化，并对照独立标量参考检查。导出`rtl/hog_svm_model.v`、`rtl/hog_svm_weights.mem`和`tools/hog_model.py`。

重训练后必须重新生成参考向量、综合、下载和打包。上位机读取模型ID，不匹配时会拒绝检测，避免混用新权重与旧bitstream。当前权重Q12，特征Q10，原始得分Q22；界面阈值为原始得分除以2^22，默认0。NMS的IoU阈值为0.35。
