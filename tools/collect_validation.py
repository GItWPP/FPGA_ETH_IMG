"""Write the migration record only from completed local simulation/board reports."""
from pathlib import Path
import hashlib
import json
import re
from project_paths import ROOT


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if (ROOT/'rtl/img_sobel_stream_top.v').exists():
        from collect_stream_validation import main as collect_stream
        return collect_stream()
    build_summary=ROOT/'project_eth/build/build_summary.txt'
    if 'ALGORITHM_CDC=' in build_summary.read_text(encoding='utf-8'):
        from collect_clock_validation import main as collect_clock
        return collect_clock()
    band=json.loads((ROOT/'tools/board_results_eth_band/board_band_test.json').read_text(encoding='utf-8'))
    hog=json.loads((ROOT/'tools/board_results_eth_hog/board_hog_test.json').read_text(encoding='utf-8'))
    speed=json.loads((ROOT/'tools/board_results_eth_throughput/throughput.json').read_text(encoding='utf-8'))
    assert all(report['status']=='passed' for report in (band,hog,speed))
    bit=ROOT/'project_eth/build/eth_img.bit'
    assert band['bitstream_sha256']==hog['bitstream_sha256']==sha(bit)
    python_log=(ROOT/'tools/board_results/python_tests.log').read_text(encoding='utf-8')
    assert re.search(r'\nOK\s*$',python_log)
    python_count=int(re.search(r'Ran (\d+) tests',python_log)[1])
    benches=['tb_img_pixel_proc','tb_img_kernel','tb_uart_img_top','tb_img_ctrl_1080p','tb_hog_math',
             'tb_hog_uart_ctrl','tb_hog_detect_top','tb_band_uart_ctrl','tb_band_decode_top',
             'tb_eth_packet_mailbox','tb_eth_rgmii_if','tb_eth_image_core',
             'tb_eth_packet_queue','tb_eth_packet_tx_fast','tb_eth_window','tb_eth_pipeline','tb_img_byte_uram']
    for name in benches:
        directory='sim/build_eth' if name.startswith('tb_eth_') or name=='tb_img_byte_uram' else 'sim/build'
        log=(ROOT/directory/f'{name}.log').read_text(encoding='utf-8')
        assert f'PASS {name}' in log and 'Fatal:' not in log and 'FAIL' not in log,name
    for mode in ('band','hog','gamma','copy','video_copy','video_hog'):
        report=json.loads((ROOT/f'tools/board_results/exe_{mode}.json').read_text(encoding='utf-8'))
        assert report['status']=='passed' and report['frozen'],mode
    exe_acceptance=json.loads((ROOT/'tools/board_results/exe_acceptance.json').read_text(encoding='utf-8-sig'))
    assert exe_acceptance['status']=='passed'
    assert exe_acceptance['executable_sha256']==sha(ROOT/'tools/dist/ETH_Image_ZU4EV.exe'),'Retest the changed executable'
    cdc=(ROOT/'project_eth/build/cdc.rpt').read_text()
    assert not re.search(r'^CDC-\d+\s+Critical',cdc,re.M)
    warnings=re.findall(r'^(CDC-\d+)\s+Warning\s+(\d+)',cdc,re.M)
    assert warnings==[('CDC-6','4'),('CDC-15','80')],warnings
    from record_build_sources import inputs
    assert json.loads((ROOT/'project_eth/build/build_sources.json').read_text())==inputs()
    faults=json.loads((ROOT/'tools/board_results_eth_window/window_faults.json').read_text())
    assert faults['status']=='passed' and faults['bitstream_sha256']==sha(bit)
    assert speed['bitstream_sha256']==sha(bit)
    utilization=(ROOT/'project_eth/build/utilization.rpt').read_text()
    def used(label):
        return re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([0-9.]+)',utilization,re.M)[1]
    luts,registers,brams,dsps=[used(label) for label in ('CLB LUTs','CLB Registers','Block RAM Tile','DSPs')]
    skew=(ROOT/'project_eth/build/bus_skew.rpt').read_text()
    assert 'VIOLATED' not in skew
    build=dict(line.split('=',1) for line in (ROOT/'project_eth/build/build_summary.txt').read_text().splitlines())
    assert float(build['SETUP_SLACK_NS'])>=0 and float(build['HOLD_SLACK_NS'])>=0
    host=json.loads((ROOT/'tools/board_results_host/optimized.json').read_text(encoding='utf-8'))
    baseline=json.loads((ROOT/'tools/board_results_host/baseline.json').read_text(encoding='utf-8'))
    assert host['status']=='passed' and baseline['status']=='passed'
    assert host['bitstream_sha256']==sha(bit)==baseline['bitstream_sha256']
    assert host['client_sha256']==sha(ROOT/'tools/eth_image.py')
    assert host['codec_sha256']==sha(ROOT/'tools/rgb565_codec.py')
    assert host['image_sha256']==baseline['image_sha256']==sha(ROOT/host['image'])
    copy=json.loads((ROOT/'tools/board_results/exe_copy.json').read_text(encoding='utf-8'))
    old_copy=json.loads((ROOT/'tools/board_results_host/baseline_exe_copy.json').read_text(encoding='utf-8'))
    assert all(copy['transfer_metrics'][x]>=0 for x in ('encode_seconds','decode_seconds','verify_seconds','total_seconds'))
    urams=used('URAM')
    selected=[frame for frame in band['frames'] if frame['name'].startswith('sample_')]
    lines=['# ZU4EV图像与视频验证记录','',
           '日期：2026-10-22。器件XCZU4EV-SFVC784-2-I，Vivado2024.2。板卡通过JTAG识别为xczu4_0并成功配置；电脑以太网2协商到1 Gbps。',
           '', '## 功能与仿真', '',
           f'- Python：{python_count}项通过，其中25项以真实本地UDP套接字验证包边界、窗口、请求/回包丢失、乱序、有界重试、错误来源及校验失败。',
           '- 本轮仅改上位机，RTL、XDC和IP配置哈希与v1.3硬件一致，复用既有17项RTL自检和实现报告。',
           '- 全部17个RTL自检通过；网络核心199个完整GMII事务逐字节对照，包含ARP、FCS、IP/UDP checksum、应用CRC、8种算法、完整HOG/Band流程及重复/冲突请求。',
           '- RGMII使用官方原语模型验证32字节双向DDR顺序、EN/ER编码和转发时钟。异步邮箱验证最大1038字节、奇数checksum、读反压、忙时保护、丢弃和复位。',
           '- 窗口GMII测试逐字节对照193个回包，覆盖64包突发、64槽回绕、混合端点、最早缓存槽重发、冲突、请求乱序、端点隔离、错误保留缓存和会话失效。队列验证满64槽、失败回滚、160包并发读写和复位；组包器验证1024字节无气泡输出及100拍反压。',
           '- 独立流水线在600微秒输出反压下验证193个响应、满应答队列、两个占用输入bank、字节及端点稳定；UltraRAM逐项验证262144字节、所有lane与稀疏覆盖写入。',
           '- 原有9个算法/协议自检保持通过；Band算法自检包含当前4张点阵图片及3个合成/变换样例。',
           '', '## 实板', '',
           '| 当前图片 | 采样记录 | 数据行 | 数据位 | UDP流程秒数 |',
           '| --- | --- | --- | --- | --- |']
    lines.extend(f'| {f["name"]} | {f["cells"]} | {f["data_rows"]} | {f["data_bits"]} | {f["network_seconds"]:.3f} |' for f in selected)
    lines+=['', '- Band逐条比较坐标、位值和标志，另通过降亮度、已知合成图、空白/溢出拒绝、重复DATA/RUN/READ及跨算法缓存和会话失效测试。',
            f'- HOG覆盖当前10张图片及2个合成帧，共{len(hog["hog_frames"])*495}个得分逐项相同；原有8种图像算法共{len(hog["image_transfers"])}次传输逐像素一致。模型仍为7803AC83。',
            f'- Band与HOG回归重试次数分别为{band["retry_count"]}和{hog["retry_count"]}。',
            '- 打包exe的Band、HOG、Gamma、1920×1080原图、视频原图及视频HOG均在frozen=True状态下通过真实GUI工作线程；Band二进制查看及导出可用，预览缩放/适应窗口通过。',
            '', '## 速度与范围', '',
            f'- 原生1920×1080复制往返{speed["seconds"]:.6f}秒，返回{speed["image_bytes"]:,}字节并与原始RGB565完全相同，重试{speed["retries"]}次。',
            f'- 有效图像吞吐{speed["useful_image_MB_per_second"]:.3f} MB/s，双向应用负载合计{speed["duplex_payload_Mbps"]:.3f} Mbps。该值不含文件转换、参考检查和预览绘制。',
            '- 物理链路1 Gbps；普通图像DATA默认32包、上限64包窗口，双包解析、算法计算和独立结果发送并行，窗口内旧请求直接回放结果。HOG/Band仍使用单包命令事务。吞吐取指定窗口逐字节校验成功试验的中位耗时，重复次数见窗口表说明，实际业务吞吐与链路速率分别记录。',
            '- Band仍为16～512 × 16～512近水平点阵；每行至少5点，末两行同步。逐项回归不代表真实码流误码率或HOG检测准确率。',
            '', '## 实现与时序边界', '',
            '- 综合层级包含eth_udp_stack、img_stream_top、eth_image_rx、tx_mailbox及RGMII接口，与移植方案一致。',
            f'- {luts} LUT、{registers}寄存器、{brams}/128 BRAM、{urams}/48 UltraRAM、{dsps} DSP；无latch，DRC无错误。',
            f'- 内部建立裕量{build["SETUP_SLACK_NS"]} ns，保持裕量{build["HOLD_SLACK_NS"]} ns；无无时钟或未约束内部端点。',
            '- CDC无critical项。4个CDC-6为整包队列的接收7位、发送4位Gray提交/释放指针，三级同步并约束源至首级最大延迟8ns和bus skew 4ns；80个CDC-15为原ARP稳定元数据。XPM双时钟块RAM保存队列数据与描述符，不整体切断时钟域，bus skew检查通过。',
            '- 参考板PHY RXDLY/TXDLY和PCB走线未提供外部I/O延迟数值。保留15项缺失输入/输出延迟提示；RGMII外部接口尚未正式签核，内部收敛及功能实测不能替代板级时序参数。',
            '', '## 已验收运行文件', '',
            f'- eth_img.bit SHA256：`{sha(bit)}`。',
            f'- ETH_Image_ZU4EV.exe SHA256：`{sha(ROOT/"tools/dist/ETH_Image_ZU4EV.exe")}`。',
            '- 详细日志与图片留在tools/board_results*、sim/build*和project_eth/build；测试输入统一来自本项目test_img。当前项目与UART_IMG测试图片内容一致。', '']
    lines+=['## 窗口性能对比', '', '| 窗口 | 1080p中位耗时/秒 | 单图有效吞吐/Mbps | 重试合计 |', '| --- | --- | --- | --- |']
    for window in sorted(set(row['window'] for row in speed['trials'])):
        trials=sorted((row for row in speed['trials'] if row['window']==window),key=lambda row:row['seconds'])
        trial=trials[len(trials)//2]
        lines.append(f"| {window} | {trial['seconds']:.6f} | {trial['useful_image_Mbps']:.3f} | {sum(row['retries'] for row in trials)} |")
    lines+=['', '- 本轮上位机优化后以默认32包窗口独立测5次；其他窗口的历史比较见legacy_ethernet/验证记录_v1.3.0.md。', '- 首版基线3.825255秒，单图8.673 Mbps。v1.2版8包窗口为0.675484秒、49.117Mbps。v1.3版32包窗口为0.134074秒、247.458Mbps。本轮新客户端对32包窗口进行复测；不同轮次受主机调度影响。',
            '- 实板另外主动丢弃一个请求、丢弃最早的回包、颠倒请求顺序，三种情况均在64包窗口下自动恢复且完整130KiB结果相同，覆盖缓存回绕。',
            '- GUI分别显示网络传输耗时/单图有效Mbps及含图片转换、参考校验和显示准备的总耗时。', '']
    video=json.loads((ROOT/'tools/board_results_video/video_acceptance.json').read_text())
    assert video['status']=='passed' and video['bitstream_sha256']==sha(bit)
    assert video['video_sha256']==sha(ROOT/'test_video/fpga_demo.mp4')
    for mode in ('video_copy','video_hog'):
        frozen=json.loads((ROOT/f'tools/board_results/exe_{mode}.json').read_text(encoding='utf-8'))
        assert frozen['pause_resume_stop']=='passed' and frozen['stats']['state']=='finished'
    lines+=['## 视频与仪表界面', '',
            '- 输入为test_video/fpga_demo.mp4，640×360、30 FPS、180帧、6秒，由本项目test_img三张图片生成。电脑解码/等比例缩放后发送，图像算法和HOG特征/分类在FPGA执行。',
            '- 视频使用当前流水线bitstream；时钟与引脚不变；每帧独立会话与CRC检查，原图逐字节比对。普通图像模式默认32包窗口，HOG保持原有独立命令。',
            '- UI采用参考图的左侧控制栏、右侧双画面、黑底绿字指标卡。视频保留缩放/拖动位置，左右画面按完整帧对更新；显示队列容量1。',
            '', '| 算法 | 显示帧尺寸 | 实测处理FPS | 处理帧数 | 跳过帧数 | 重试 |', '| --- | --- | --- | --- | --- | --- |']
    for case in video['cases']:
        lines.append(f"| {case['name']} | {case['size'][0]}×{case['size'][1]} | {case['processed_fps']:.2f} | {case['processed']} | {case['skipped']} | {case['retries']} |")
    lines+=['', '- 各模式均完整播放至最后源帧，首末采样帧与独立整数参考比较一致。另通过逐帧模式4帧全处理、零跳帧；GUI完成事件后重新读取最终快照，防止停止瞬间状态竞争。FPS为本次6秒样例实测，其他视频/分辨率/算法会有差异。',
            '- 打包EXE实际解码MP4并通过原图、HOG完整播放及暂停/继续/停止/重新播放测试；帧率详见本轮记录，均零重传。停止和断链等待可在接收轮询中取消。',
            '- 视频非原图模式以协议CRC、返回长度和会话完整性作运行检查，不在电脑重复计算每帧参考；独立参考仅在验收脚本中检查采样帧。静态图片仍执行完整参考校验。',
            '- 第一版按文件报告的帧率调度本地视频文件；音频、摄像头、网络流及变帧率精确同步未纳入本次范围。', '']
    old_total=float(re.search(r'总计 ([0-9.]+) 秒',old_copy['gui_status'])[1])
    metrics=copy['transfer_metrics']
    lines+=['## 上位机快速收发与RGB565转换', '',
            '- UDP按完整报文检查MAGIC、版本、精确长度及一次CRC；窗口使用非阻塞收发、select按需等待、最小堆重试期限及预分配结果缓冲。退出窗口后恢复套接字模式。',
            '- 静态图片和视频共用rgb565_codec，保持RGB565小端及颜色高位复制语义；UART标量模型和完整算法参考检查保持独立。',
            '- 9个新增测试覆盖整包边界/错误版本/CRC、单次校验、灰度/RGB/RGBA/调色板转换、乱序字节保存、超时/错误/取消的模式恢复及发送缓冲反压。全部65536种RGB565颜色仍与标量参考逐项一致。', '',
            '| 1080p指标 | 旧版 | 新版 |', '| --- | --- | --- |',
            f"| 编码中位秒数 | {baseline['encode_median']:.6f} | {host['encode_median']:.6f} |",
            f"| 解码中位秒数 | {baseline['decode_median']:.6f} | {host['decode_median']:.6f} |",
            f"| 交替测试中位Mbps（各5次） | {host['alternating_medians']['baseline']:.3f} | {host['alternating_medians']['optimized']:.3f} |",
            f"| frozen EXE后台总耗时/秒 | {old_total:.3f} | {metrics['total_seconds']:.3f} |", '',
            f"- EXE传输{metrics['network_seconds']:.6f}秒、{metrics['image_Mbps']:.3f} Mbps；编码{metrics['encode_seconds']:.6f}秒、参考检查{metrics['verify_seconds']:.6f}秒、解码{metrics['decode_seconds']:.6f}秒。",
            f"- GUI自动验收观察到的发送至界面更新耗时{copy['gui_wait_seconds']:.3f}秒；打开文件在计时之前。EXE旧/新结果PNG均与独立标量转换逐字节相同。",
            '- 基准与EXE均零重传；吞吐受主机负载/调度影响，不将单次峰值作为固定带宽。逐项数据位于tools/board_results_host。', '']
    target=ROOT/'doc/验证记录.md'
    target.write_text('\n'.join(lines),encoding='utf-8')
    print('PASS validation record:',target)


if __name__=='__main__':
    main()
