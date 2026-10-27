# EXE 打包、独立工程与代码风格验证

日期：2026-10-21。按用户要求完成独立工程接入、RTL/仿真风格整理、Windows EXE 打包和实板复验。

本文件为 320×240 版本的历史验收。后续 1920×1080 扩展、当前 bitstream 和新版 UART_Image_Tool_1080p.exe 的结果见同目录《1080p扩展验证.md》。

## 可直接运行的上位机

发布文件：`tools/dist/UART_Image_Tool.exe`。

- Windows x64，单文件、GUI 子系统，双击后显示中文界面。
- 无需安装 Python、Pillow 或 pyserial；无需配套 DLL 或源码文件夹。
- 文件大小：20066556 字节，约 20.1 MB。
- SHA256：`db2449b7a6d30364b5c3b48fad4f68caf1037a5a1a23e06449763b79052c4010`。
- 使用：选择 COM11、1500000、图片尺寸和模式，然后发送；结果通过整数参考模型检查后显示，可保存 PNG/BMP。

打包工具为 PyInstaller 6.22.3，采用 onefile/windowed，禁用 UPX。依赖固定在 `tools/requirements-packaging.txt`，隔离环境在 `tools/.packaging_venv`。重新打包执行 `tools/package_exe.ps1`，中间产物在 `tools/packaging/build`，最终 EXE 在 `tools/dist`。

打包模式说明参考 [PyInstaller 官方文档](https://pyinstaller.org/en/stable/operating-mode.html)，具体参数参考 [官方使用文档](https://pyinstaller.org/en/stable/usage.html)。

## 独立运行测试

将 EXE 单独复制到 `tools/packaging/portable_smoke`，运行进程 PATH 仅保留 Windows/System32 和 Windows，未包含 Python 或虚拟环境目录；程序使用自身内嵌运行时。检查 Tk/Tcl、Pillow、串口枚举、协议解码和 GUI 预览，结果 PASS。报告确认 `frozen=true`。这证明本机独立运行测试通过，未声称在第二台全新电脑上执行过测试。

还从任意工作目录（系统 TEMP）启动正式 EXE，并调用其真实 GUI 工作线程和事件队列连接 COM11：

| 模式编号 | EXE 实际状态 | 像素比较 |
| --- | --- | --- |
| 0 | 校验通过 · 128×128 · 0.552 秒 · 重试 0 次 | PASS |
| 1 | 校验通过 · 128×128 · 0.560 秒 · 重试 0 次 | PASS |
| 2 | 校验通过 · 128×128 · 0.556 秒 · 重试 0 次 | PASS |

界面窗口在自动验收模式中隐藏；图片转换、串口传输、队列回调、结果对象和显示预览均使用正式应用代码。双击普通启动不带测试参数，会正常显示窗口。

报告位于 `tools/packaging/exe_smoke_test.json`、`exe_board_test.json`、`exe_manifest.json`，EXE 实际回传图为 `tools/packaging/exe_fpga_mode_*.png`。自动检查入口 `--self-test --report <绝对路径> [--port COM11]` 仅供验收；普通用户无需传参。

## 工程目录

使用用户已创建的 `project_uart/project_uart.xpr`，器件 xc7z020clg400-2，Vivado 2024.2。

构建脚本以 `open_project -read_only` 读取该工程的文件集，不使用 `create_project -force`，不覆盖工程配置。XPR 在本次处理前后的 SHA256 保持一致：`7f6271321e5b22ba5de980a1624270cf0e35a287f74c3380b22678c8ac0685c5`。

报告、综合/实现检查点及 bitstream 统一输出到 `project_uart/build`。原 `tools/build` 保留为首次版本的历史构建，不再作为默认输出。`tools/build.ps1` 默认使用 `C:/Xilinx/Vivado/2024.2/bin`。

已在 `项目父目录的AGENTS.md` 记录今后的独立工程目录和技能编码约定。

## 代码风格

8 个 RTL 文件和 2 个 testbench 均按 verilog-fpga-dev 的 coding-style.md 整理：

- 保留六字段模块说明头、作者 WANG 和原始日期。
- 统一 Parameter and Internal Signal、Main Code、Instantiation 分区；信号声明先于逻辑赋值。
- 显式 input wire/output wire/output reg，按接口分组；具名参数和端口连接逐行对齐。
- 状态转移与字节计数、CRC、缓存接口、完成标志分开；会话控制按请求、响应、参数、像素、缓存职责拆分。
- 使用具名、定宽状态/协议常量及简短中文时序注释；保留同步 BRAM 控制复位，防止异步 RAM 控制告警。
- 阻塞赋值用于组合逻辑，非阻塞赋值用于时钟逻辑，组合分支有默认值。

`python tools/check_rtl_style.py` 检查 10 个文件的模块头、分区、显式端口和逐行语句/连接，结果 PASS；该检查只验证布局要求，功能由仿真和板卡验证。

## 重新验证

Python 8 项主机自检通过。Vivado 2024.2 XSim：196608 个模式/像素组合及反压、复位检查通过；系统位级仿真 8032 个回传字节与 Python 参考一致，保留原协议、时序、恢复和重试覆盖。

```text
PART=xc7z020clg400-2
CLOCK_HZ=50000000 BAUD=1500000
SETUP_SLACK_NS=12.491
HOLD_SLACK_NS=0.111
BITSTREAM=./project_uart/build/uart_img.bit
```

实现后：695 LUT、755 FF、2 RAMB18、1 DSP。时序通过，无缺失时钟和未约束内部端点。

默认 `report_drc` 记录 25 条 Warning：DSP 输入/乘法流水建议 3 条、LUT 配对/A6 常量连接提示 21 条、未实例化 PS7 的纯 PL 提示 1 条；没有 Error 或 Critical Warning。未降级或屏蔽这些规则；详情完整保存在 `project_uart/build/drc.rpt`。write_bitstream 前置检查通过并生成 bitstream。本记录保留工具的实际告警，不把默认 DRC 描述为零告警。

新 bitstream 已通过 JTAG 下载到用户确认的唯一 XC7Z020，启动状态 HIGH。以下实际验收全部逐字节比较通过：

| 尺寸 | 模式 | 实测往返耗时 | 重试 | 比较 |
| --- | --- | --- | --- | --- |
| 1×1 | copy | 0.007 s | 0 | PASS |
| 1×1 | gray | 0.007 s | 0 | PASS |
| 1×1 | invert | 0.007 s | 0 | PASS |
| 128×128 | copy | 0.548 s | 0 | PASS |
| 128×128 | gray | 0.546 s | 0 | PASS |
| 128×128 | invert | 0.546 s | 0 | PASS |
| 320×240 | copy | 2.542 s | 0 | PASS |
| 320×240 | gray | 2.542 s | 0 | PASS |
| 320×240 | invert | 2.543 s | 0 | PASS |

额外采用 320×205 的图像，包含全部 65536 种 RGB565 颜色和 64 个填充像素；三种模式均在实际板卡上逐像素比较通过，重试 0 次。结果在 `tools/board_results_project_uart/exhaustive_colors.json`。

实际串口还检查了坏 CRC、截断超时、重复 DATA/END 和序号错误恢复。完整 JSON 和返回 PNG 在 `tools/board_results_project_uart/`，COM11 在测试结束后已释放。

当前 bitstream SHA256：`66e2bed0add3538412b04352a52f70f56ac5ad2efb93de6c9c0887e18ef0afbc`。JTAG 配置掉电失效，本次未写 QSPI。自动测试未覆盖所有手动文件对话框和长时间运行场景。
