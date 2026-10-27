# GitHub公开仓库整理

日期：2026-10-22。公开仓库：`GItWPP/UART_IMG`，默认分支`main`。

## 公开范围

保留RTL、模型权重、XDC、用户已有的独立Vivado XPR、仿真程序、上位机/训练/验证工具、设计说明，以及当前`test_img`下10张测试图片。Windows EXE与bitstream通过Release提供，并附SHA256和源码提交号。

Vivado/XSim缓存、波形、DCP、Python环境、打包缓存、生成结果、训练数据集、训练缓存、旧备份、原厂整本PDF和已被FPGA实现取代的软件试验原型留在本机，Git忽略这些内容。没有清空用户的缓存、数据集或历史备份。未额外指定项目或第三方图片的开源许可证。

## 可复现性修正

- `test_img/manifest.json`统一管理Band、HOG与图像处理分组。Band使用1～4号图；HOG不再读取本机训练数据集或缺失的`people1.jpg`。
- `1.png`是原先`5.png`的同一文件，保留其已验收二进制作为回归参考；不依赖已移走的`5_debug.png`。
- HOG/Band仿真每次从现有图片重新生成向量。Band的include文件使用相对路径，干净克隆无需复制旧缓存。
- XPR保留器件、顶层、源文件与运行策略，移除机器路径和本地增量DCP依赖；未重新创建工程。
- 所有Python入口按脚本位置定位仓库，解释器参数默认为`python`。Vivado安装位置可通过`-VivadoBin`覆盖。
- 添加Windows/Python3.13的GitHub Actions检查：项目引用、测试图片、模型ROM一致性、Python测试、HDL格式及向量再生成；硬件综合/仿真仍在安装Vivado的本机执行。

## 验证方式

发布前以暂存的源码生成另一目录的干净副本，在副本中运行Python检查、全部9个RTL自检，并只读打开Vivado工程验证迁移路径。测试图片来自该副本的`test_img`。

RTL数据通路和模型权重未更改；Release沿用2026-10-21已综合、布局布线并上板验收的bitstream和EXE。其时序与资源记录见`Band_FPGA设计与验证.md`。当前图片1～4号的Band结果还会与整数参考逐条对照；它们没有原始物理码流真值，不能将回归通过解读为真实误码率为零。

仓库验证入口：`python tools/verify_repository.py`。完整测试入口：`python tools/uart_image.py selftest`及`sim/run_sim.ps1`。发布产物收集：`python tools/package_release.py --tag v1.0.0`，输出在被Git忽略的`tools/dist/UART_IMG-v1.0.0`。

## 本次结果

- 干净副本：64项Python测试、全部9个RTL自检通过；Band自检现在包含4张当前图片、已知码流合成图、降低亮度图和空白图，共7帧。
- Vivado2024.2只读打开迁移后的XPR，通过器件、顶层和全部RTL引用检查，没有本地增量DCP依赖。
- COM11实板：4张Band图的采样坐标、位值及标志与整数参考逐条相同；同步行排除后的可见数据如下。另通过空白/溢出拒绝、重复包及跨算法缓存/会话测试。
- HOG实板回归覆盖`test_img`全部10张图片及2个合成帧，共5940个得分；另完成原有8种图像算法共24次传输，均与参考逐项相同。
- HOG模型保持7803AC83；RTL与发布的EXE、bitstream未改变。图片实测的数值一致性不等于目标检测准确率或Band真实码流正确率。

| Band图片 | 总采样记录（含同步） | 数据行数 | 可见数据位数 | 整次实测约 |
| --- | --- | --- | --- | --- |
| 1.png | 637 | 19 | 575 | 2.75秒 |
| 2.png | 639 | 19 | 578 | 2.73秒 |
| 3.png | 637 | 19 | 575 | 2.73秒 |
| 4.png | 636 | 19 | 576 | 2.73秒 |

执行日志及图像结果留在本地忽略目录；仓库中保留上述汇总和可重新运行的脚本。旧的本机日志归档到`tools/local_archive`，没有删除训练数据或备份。
