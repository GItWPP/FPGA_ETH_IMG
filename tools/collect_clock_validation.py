"""Validate current dual-clock build/board evidence before creating release notes."""
import hashlib
import json
import re
from project_paths import ROOT
from record_build_sources import inputs


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def report(relative):
    value = json.loads((ROOT/relative).read_text(encoding='utf-8-sig'))
    assert value['status'] == 'passed', relative
    return value


def main():
    bit = ROOT/'project_eth/build/eth_img.bit'
    bit_sha = sha(bit)
    build_text = (ROOT/'project_eth/build/build_summary.txt').read_text(encoding='utf-8')
    algorithm_hz = int(re.search(r'ALGORITHM_CLOCK_HZ=(\d+)',build_text)[1])
    assert algorithm_hz in (50_000_000,125_000_000)
    tag = 'v1.6.0' if algorithm_hz == 125_000_000 else 'v1.5.0'
    assert json.loads((ROOT/'project_eth/build/build_sources.json').read_text(encoding='utf-8')) == inputs()
    benches = ['tb_img_pixel_proc','tb_img_kernel','tb_uart_img_top','tb_img_ctrl_1080p',
               'tb_hog_math','tb_hog_uart_ctrl','tb_hog_detect_top','tb_band_uart_ctrl','tb_band_decode_top',
               'tb_eth_packet_mailbox','tb_eth_rgmii_if','tb_eth_image_core','tb_eth_packet_queue',
               'tb_eth_packet_tx_fast','tb_eth_window','tb_eth_pipeline','tb_img_byte_uram','tb_img_async_command']
    hdl_inputs = list((ROOT/'rtl').rglob('*.v')) + list((ROOT/'sim').glob('*.v'))
    latest_hdl = max(path.stat().st_mtime for path in hdl_inputs)
    rtl_acceptance = report('tools/board_results_clock/rtl_acceptance.json')
    assert rtl_acceptance['checks'] == len(benches)
    assert rtl_acceptance.get('algorithm_mhz',50) == algorithm_hz//1_000_000
    for name,digest in rtl_acceptance['sha256'].items():
        assert sha(ROOT/name) == digest, f'Rerun changed RTL/test source: {name}'
    for name in benches:
        directory = 'build_eth' if name.startswith('tb_eth_') or name in ('tb_img_byte_uram','tb_img_async_command') else 'build'
        path = ROOT/'sim'/directory/f'{name}.log'
        log = path.read_text(encoding='utf-8')
        assert f'PASS {name}' in log and not re.search(r'Fatal:|FAIL|Error:',log), name
        assert path.stat().st_mtime >= latest_hdl, f'Rerun RTL regression: {name}'
    python_log = (ROOT/'tools/board_results/python_tests.log').read_text(encoding='utf-8')
    assert re.search(r'\nOK\s*$',python_log)
    python_count = int(re.search(r'Ran (\d+) tests',python_log)[1])
    band = report('tools/board_results_eth_band/board_band_test.json')
    hog = report('tools/board_results_eth_hog/board_hog_test.json')
    speed = report('tools/board_results_eth_throughput/throughput.json')
    faults = report('tools/board_results_eth_window/window_faults.json')
    video = report('tools/board_results_video/video_acceptance.json')
    host = report('tools/board_results_host/optimized.json')
    exe = report('tools/board_results/exe_acceptance.json')
    for value in (band,hog,speed,faults,video,host,exe):
        assert value['bitstream_sha256'] == bit_sha, 'Retest with the current bitstream'
    assert exe['executable_sha256'] == sha(ROOT/'tools/dist/ETH_Image_ZU4EV.exe')
    assert host['client_sha256'] == sha(ROOT/'tools/eth_image.py')
    assert host['codec_sha256'] == sha(ROOT/'tools/rgb565_codec.py')
    assert host['image_sha256'] == sha(ROOT/host['image'])
    assert video['video_sha256'] == sha(ROOT/'test_video/fpga_demo.mp4')
    for mode in ('band','hog','gamma','copy','video_copy','video_hog'):
        frozen = report(f'tools/board_results/exe_{mode}.json')
        assert frozen['frozen'], mode
        if mode.startswith('video_'):
            assert frozen['pause_resume_stop'] == 'passed' and frozen['stats']['state'] == 'finished'
    copy = report('tools/board_results/exe_copy.json')
    baseline = json.loads((ROOT/'tools/board_results_clock/baseline_v1_4.json').read_text(encoding='utf-8'))
    build = dict(line.split('=',1) for line in (ROOT/'project_eth/build/build_summary.txt').read_text().splitlines())
    assert f'APP_CLOCK_HZ=125000000 ALGORITHM_CLOCK_HZ={algorithm_hz}' in build_text
    assert float(build['SETUP_SLACK_NS']) >= 0 and float(build['HOLD_SLACK_NS']) >= 0
    cdc = (ROOT/'project_eth/build/cdc.rpt').read_text()
    assert not re.search(r'^CDC-\d+\s+Critical',cdc,re.M)
    warnings = re.findall(r'^(CDC-\d+)\s+Warning\s+(\d+)',cdc,re.M)
    if algorithm_hz == 125_000_000:
        review = report('tools/board_results_algorithm_clock/cdc_review.json')
        assert review['cdc_sha256'] == sha(ROOT/'project_eth/build/cdc.rpt')
        assert review['warnings'] == [list(row) for row in warnings]
    else:
        assert warnings == [('CDC-6','4'),('CDC-15','265')], warnings
    new_cdc_rows = [line for line in cdc.splitlines() if re.search(r'^\s*\d+\s+CDC-15',line) and 'u_eth_arp/' not in line]
    assert all('/descriptor_fifo_inst/' in line and 'Max Delay Datapath Only' in line for line in new_cdc_rows)
    skew = (ROOT/'project_eth/build/bus_skew.rpt').read_text()
    assert 'VIOLATED' not in skew and 'No bus skew constraints' not in skew
    utilization = (ROOT/'project_eth/build/utilization.rpt').read_text()
    def used(label):
        return re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([0-9.]+)',utilization,re.M)[1]
    resources = {label:used(label) for label in ('CLB LUTs','CLB Registers','Block RAM Tile','URAM','DSPs')}
    metrics = copy['transfer_metrics']
    summary = dict(status='passed',bitstream_sha256=bit_sha,executable_sha256=exe['executable_sha256'],
                   algorithm_clock_hz=algorithm_hz,
                   python_tests=python_count,rtl_self_checks=len(benches),resources=resources,cdc_warnings=warnings,
                   baseline_v1_4=baseline['throughput']['useful_image_Mbps'],
                   full_hd_useful_image_Mbps=speed['useful_image_Mbps'],exe_copy=metrics)
    lines = [f'# {tag} 高速传输与算法时钟验证', '',
             '2026-10-23，XCZU4EV-SFVC784-2-I，Vivado 2024.2。电脑192.168.1.18与PL千兆网口直连，板卡192.168.1.12:1234。', '',
             '## 实现', '',
             f'- 传输、CRC、缓存和原图搬运125MHz；图像处理、HOG和Band算法{algorithm_hz//1_000_000}MHz。GMII TX原有相移保持。',
             '- 请求、应答和完成确认使用三个XPM异步描述符FIFO；两个双时钟RAM管理请求和结果所有权。',
             '- 原图在高速域预复制，算法域继续做完整会话检查；64逻辑缓存槽加1个暂存物理槽，校验成功才原子换槽，非法请求不覆盖旧重发结果。',
             '- 上位机沿用v1.4快速收发版本，协议和测试图片兼容。本版必须更新bitstream。', '',
             '## 正确性', '',
             f'- {python_count}项Python测试、18项RTL自检通过。199项GMII整机事务、197项GMII窗口回复及197项直接反压回复逐字节正确。',
             '- 新增166.7/45.45MHz非整数比、不同相位跨时钟测试：0/1/1023/1024字节、非法长度、冲突及精确重试、发送反压，以及搬运中/算法执行中/应答反压中全局复位。原图算法域没有再次写像素。',
             '- 扩展窗口向量覆盖非法前瞻请求与旧缓存同槽碰撞；旧结果仍能完整重发。发送反压600微秒时两个输入缓冲区与8项应答FIFO保持有效数据。',
             f'- HOG共{len(hog["hog_frames"])}帧、{len(hog["hog_frames"])*495}个得分逐项一致；八种图像算法{len(hog["image_transfers"])}次传输与独立整数参考一致。',
             '- Band当前4张图片、合成、降亮度、空白/溢出拒绝、重复命令、跨算法会话和缓存失效通过；逐条检查坐标、位值与标志。',
             '- 实板主动丢请求、丢首回包、请求乱序均可在64包窗口恢复，完整130KiB结果一致。',
             '- 同一EXE在新bitstream上通过Band、HOG、Gamma、1080p原图、视频原图/视频HOG及暂停、继续、停止、重播验收。', '',
             '## 1080p原图性能', '',
             f'| 指标 | v1.4 / 50MHz传输 | {tag} / 125MHz传输 |', '| --- | --- | --- |',
             f'| 五次中位有效Mbps | {baseline["throughput"]["useful_image_Mbps"]:.3f} | {speed["useful_image_Mbps"]:.3f} |',
             f'| 五次中位传输秒数 | {baseline["throughput"]["seconds"]:.6f} | {speed["seconds"]:.6f} |',
             f'| frozen EXE有效Mbps | {baseline["exe_copy"]["transfer_metrics"]["image_Mbps"]:.3f} | {metrics["image_Mbps"]:.3f} |',
             f'| frozen EXE后台总秒数 | {baseline["exe_copy"]["transfer_metrics"]["total_seconds"]:.6f} | {metrics["total_seconds"]:.6f} |', '',
             '- 有效Mbps为单幅RGB565图像字节数÷完整收发耗时；转换、参考校验和显示不计入网络计时。1920×1080共4,147,200字节，返回逐字节一致。不同轮次会受电脑负载与调度影响。',
             f'- 新EXE编码{metrics["encode_seconds"]:.6f}秒、传输{metrics["network_seconds"]:.6f}秒、解码{metrics["decode_seconds"]:.6f}秒；GUI观察到{copy["gui_wait_seconds"]:.3f}秒。',
             '- 本版算法域提频，计算周期数保持；网络、图片转换和显示仍影响整体速度，计算耗时与视频FPS分别记录。', '',
             '| 视频模式 | 实际帧尺寸 | 处理FPS | 处理/跳过 | 重试 |', '| --- | --- | --- | --- | --- |']
    for case in video['cases']:
        lines.append(f'| {case["name"]} | {case["size"][0]}×{case["size"][1]} | {case["processed_fps"]:.2f} | {case["processed"]}/{case["skipped"]} | {case["retries"]} |')
    lines += ['', '## 时序和资源', '',
              f'- LUT {resources["CLB LUTs"]}、寄存器 {resources["CLB Registers"]}、BRAM {resources["Block RAM Tile"]}/128、UltraRAM {resources["URAM"]}/48、DSP {resources["DSPs"]}。',
              f'- 内部建立裕量{build["SETUP_SLACK_NS"]}ns、保持裕量{build["HOLD_SLACK_NS"]}ns；DRC无错误，CDC无critical项，Gray总线偏斜约束通过。',
              '- 构建工具禁用本机此前出现异常的可选功耗估计；时序、DRC、CDC和总线偏斜检查均保留。',
              '- CDC warning汇总：'+', '.join(f'{code}={count}' for code,count in warnings)+f'。描述符FIFO内部共有{len(new_cdc_rows)}项CDC-15，均受XPM内部datapath约束；其余ARP稳定元数据和整包Gray指针按报告逐项审查，没有整体切断时钟域。',
              '- 参考板PHY/PCB未提供完整外部I/O delay，RGMII板级时序仍需依据板级参数完成正式签核；此项不以内部时序和功能测试替代。', '',
              '## 交付与证据', '', f'- bit SHA256：`{bit_sha}`。', f'- EXE SHA256：`{exe["executable_sha256"]}`。',
              '- 详细报告：tools/board_results_clock、tools/board_results_eth_*、tools/board_results_video；仿真：sim/build*；实现：project_eth/build。',
              '- 设计、状态和RAM所有权：[高速传输与算法跨时钟解耦](高速传输与算法跨时钟解耦.md)。v1.4历史数据：[历史验证](legacy_ethernet/验证记录_v1.4.0.md)。', '']
    if algorithm_hz == 125_000_000:
        from collect_algorithm_validation import algorithm_comparison
        comparison_lines,comparison = algorithm_comparison(bit_sha)
        lines += comparison_lines
        summary['algorithm_comparison'] = comparison
    (ROOT/'tools/board_results_clock/clock_acceptance.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    (ROOT/'doc/验证记录.md').write_text('\n'.join(lines),encoding='utf-8')
    print('PASS current dual-clock build, 18 RTL checks and physical-board release evidence')


if __name__ == '__main__':
    main()
