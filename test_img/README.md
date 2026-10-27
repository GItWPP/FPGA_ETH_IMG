# 测试图片

本目录是全部用户测试图片的唯一入口。分组在`manifest.json`维护，路径通过`tools/project_paths.py`解析，支持克隆到其他目录运行。

| 图片 | 尺寸 | 用途 |
| --- | --- | --- |
| 1.png、2.png、3.png、4.png | 512×512 | 固定间距Band暗点解码 |
| hog_validation_scene.png、hog_val.png、test1.png | 320×240 | HOG/图像处理回归 |
| test.png | 425×454 | 任意尺寸和HOG回归 |
| Ai-marketing.jpg | 1500×1080 | 大图处理和HOG等比例补边 |
| 1920x1080_fpga_copy.png | 1920×1080 | 最大尺寸图像 |

`1.png`与此前记录中的`5.png`内容相同，SHA256为`4B2F33AB25FEF30C5C0BB8F1118D86E739AE184BD3937972A9FD9A3247899A3D`。`expected/band_1_bits.txt`保留该图已通过FPGA验收的19行、575位回归结果，末两行同步点已排除；这是回归参考，不是原始物理码流真值。

仿真还会生成噪声、边界、空白、随机像素等合成激励，用于检查已知码流和错误路径；这些生成文件不进入版本库。训练数据集独立保存在本地`tools/datasets`，不作为本仓库的应用测试图片。
