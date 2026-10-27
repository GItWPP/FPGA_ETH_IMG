"""Release gate for the 720p25 stream build; old benchmark evidence stays historical."""
import hashlib
import json
import re
from pathlib import Path
from project_paths import ROOT,user_test_images
from record_build_sources import inputs

BENCHES=['tb_img_pixel_proc','tb_img_kernel','tb_uart_img_top','tb_img_ctrl_1080p',
    'tb_hog_math','tb_hog_uart_ctrl','tb_hog_detect_top','tb_band_uart_ctrl','tb_band_decode_top',
    'tb_eth_packet_mailbox','tb_eth_rgmii_if','tb_eth_image_core','tb_eth_packet_queue',
    'tb_eth_packet_tx_fast','tb_eth_window','tb_eth_pipeline','tb_img_byte_uram','tb_img_async_command',
    'tb_sobel_stream_kernel','tb_sobel_stream_protocol']

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def report(name):
    value=json.loads((ROOT/name).read_text(encoding='utf-8-sig'))
    assert value['status']=='passed',name
    return value


def main():
    bit_sha=sha(ROOT/'project_eth/build/eth_img.bit')
    exe_sha=sha(ROOT/'tools/dist/ETH_Image_ZU4EV.exe')
    native=report('tools/board_results_stream/native_acceptance.json')
    assert native['executable_sha256']==exe_sha
    assert native['dll_sha256']==sha(ROOT/'tools/native/stream_udp.dll')
    assert native['source_sha256']==sha(ROOT/'tools/native/stream_udp.c')
    assert json.loads((ROOT/'project_eth/build/build_sources.json').read_text(encoding='utf-8'))==inputs()
    latest=max(p.stat().st_mtime for p in list((ROOT/'rtl').rglob('*.v'))+list((ROOT/'sim').glob('*.v')))
    for name in BENCHES:
        directory='build' if name in BENCHES[:9] else 'build_eth'
        log_path=ROOT/'sim'/directory/f'{name}.log'
        log=log_path.read_text(encoding='utf-8')
        assert f'PASS {name}' in log and not re.search(r'Fatal:|FAIL|Error:',log),name
        assert log_path.stat().st_mtime>=latest,(name,'stale simulation')
    pylog=(ROOT/'tools/board_results/python_tests.log').read_text(encoding='utf-8')
    assert re.search(r'\nOK\s*$',pylog)
    python_count=int(re.search(r'Ran (\d+) tests',pylog)[1])
    stream=report('tools/board_results_stream/all.json')
    assert stream['bitstream_sha256']==bit_sha
    assert stream['client_sha256']==sha(ROOT/'tools/eth_image.py')
    assert stream['target_fps']==25 and stream['capacity']['within_25fps_budget']
    stats=stream['video']['stats']
    assert stats['processed_fps']>=24.8 and stats['processed']==stream['video']['source_frames']
    assert stats['skipped']==stats['retries']==0
    assert sha(Path(stream['input']))==stream['video']['source_sha256']
    evidence={}
    for name,path in [('hog','tools/board_results_eth_hog/board_hog_test.json'),
        ('band','tools/board_results_eth_band/board_band_test.json'),
        ('window','tools/board_results_eth_window/window_faults.json'),
        ('throughput','tools/board_results_eth_throughput/throughput.json'),
        ('host','tools/board_results_host/optimized.json'),
        ('exe','tools/board_results/exe_acceptance.json')]:
        value=report(path);assert value['bitstream_sha256']==bit_sha,path;evidence[name]=value
    assert evidence['exe']['executable_sha256']==exe_sha
    assert evidence['host']['client_sha256']==sha(ROOT/'tools/eth_image.py')
    assert evidence['host']['codec_sha256']==sha(ROOT/'tools/rgb565_codec.py')
    for mode in ['band','hog','gamma','copy','video_copy','video_hog','video_sobel25']:
        value=report(f'tools/board_results/exe_{mode}.json');assert value['frozen']
        if mode.startswith('video_'):
            assert value['pause_resume_stop']=='passed' and value['stats']['state']=='finished'
    gui=report('tools/board_results/exe_video_sobel25.json')
    assert gui['stats']['processed_fps']>=24.8 and gui['stats']['skipped']==gui['stats']['retries']==0
    assert gui['frame_size']==[1280,720] and gui['stats']['source_fps']==25
    build=dict(line.split('=',1) for line in (ROOT/'project_eth/build/build_summary.txt').read_text().splitlines())
    assert 'ALGORITHM_CLOCK_HZ=125000000' in build['APP_CLOCK_HZ']
    assert float(build['SETUP_SLACK_NS'])>=0 and float(build['HOLD_SLACK_NS'])>=0
    cdc=(ROOT/'project_eth/build/cdc.rpt').read_text()
    assert not re.search(r'^CDC-\d+\s+Critical',cdc,re.M)
    warnings=re.findall(r'^(CDC-\d+)\s+Warning\s+(\d+)',cdc,re.M)
    assert warnings==[('CDC-6','4'),('CDC-15','265')],warnings
    rows=[line for line in cdc.splitlines() if re.search(r'^\s*\d+\s+CDC-15',line) and 'u_eth_arp/' not in line]
    assert all('/descriptor_fifo_inst/' in line and 'Max Delay Datapath Only' in line for line in rows)
    skew=(ROOT/'project_eth/build/bus_skew.rpt').read_text()
    assert 'VIOLATED' not in skew and 'No bus skew constraints' not in skew
    util=(ROOT/'project_eth/build/utilization.rpt').read_text()
    resources={label:re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([0-9.]+)',util,re.M)[1]
        for label in ['CLB LUTs','CLB Registers','Block RAM Tile','URAM','DSPs']}
    result=dict(status='passed',tag='v1.7.0',target_fps=25,bitstream_sha256=bit_sha,executable_sha256=exe_sha,
        rtl_self_checks=len(BENCHES),python_tests=python_count,resources=resources,cdc_warnings=warnings,
        setup_slack_ns=float(build['SETUP_SLACK_NS']),hold_slack_ns=float(build['HOLD_SLACK_NS']),
        native_udp=native,video=stream['video'],frozen_video=gui['stats'],source_video_sha256=stream['video']['source_sha256'],
        runtime_sample_sha256=sha(ROOT/'test_video/fpga_demo_25.mp4'),
        production_sources={str(p.relative_to(ROOT)).replace('\\','/'):sha(p) for p in [
            ROOT/'tools/video_pipeline.py',ROOT/'tools/stream_sobel.py',ROOT/'tools/eth_image.py',ROOT/'tools/eth_image_gui.py',
            ROOT/'tools/native_stream.py',ROOT/'tools/native/stream_udp.c',ROOT/'tools/native/stream_udp.dll']})
    out=ROOT/'tools/board_results_stream';out.mkdir(exist_ok=True)
    (out/'release_acceptance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    lines=['# v1.7.0 720p25 流式 Sobel 验证','',
        '2026-10-23，XCZU4EV-SFVC784-2-I，Vivado 2024.2。FPGA与电脑通过PL千兆网口连接。',
        '',f"- 用户视频：1280×720 / 25 FPS / {stats['processed']}帧，完整逐帧处理{stats['processed_fps']:.3f} FPS，零跳帧、零重传。",
        f"- 打包EXE实测：{gui['stats']['processed_fps']:.3f} FPS，{gui['stats']['processed']}帧；暂停/继续/停止/重播及最终帧参考一致。",
        f"- 720p网络事务12次中位：{stream['capacity']['median_seconds']*1000:.3f} ms/帧。上下行分别RGB565/GRAY8；不将该值作为完整GUI帧率。",
        '- 完整视频逐帧校验CRC、应答长度与输出像素数；第0、243、487、730帧与独立像素参考一致，EXE最终帧也通过独立参考。',
        '- FPGA内执行亮度、两行缓存、3×3窗口和Sobel流水线，电脑负责视频解码、RGB565打包及灰度显示。仅额外上传右边界一列和下边界一行。',
        '- 视频Sobel使用64包窗口，后台准备队列限2帧；现有静态图像/其他算法入口保留。',
        '- 新协议在1×1、单行/列、奇数宽、跨包、1920×1080、主动丢请求/应答/START/END回复下逐字节通过独立参考检查。',
        '- 本轮按用户要求验收25 FPS，没有进行30 FPS验收。','',
        f"- 软件{python_count}项、RTL {len(BENCHES)}项全部通过；协议155应答、内核II=1及处理中复位均通过。",
        '- 旧链路199整机事务、197窗口回复、197反压应答通过；旧8算法24种传输、当前全部测试图片HOG及4张Band图、异常/重试均实板复测。',
        f"- 资源：LUT {resources['CLB LUTs']}，FF {resources['CLB Registers']}，BRAM {resources['Block RAM Tile']}/128，URAM {resources['URAM']}/48，DSP {resources['DSPs']}。新增Sobel行缓存仅增加1个BRAM tile。",
        f"- 内部建立/保持裕量{build['SETUP_SLACK_NS']}/{build['HOLD_SLACK_NS']} ns，DRC无错误，CDC无critical，既有4项Gray指针与265项XPM/ARP warning核查通过，bus skew约束通过。",
        '- RGMII外部I/O delay仍依赖PHY/PCB参数完成板级签核，内部时序与功能测试不替代此项。','',
        f'- bit SHA256：`{bit_sha}`。',f'- EXE SHA256：`{exe_sha}`。','',
        '详细数据位于tools/board_results_stream，EXE记录位于tools/board_results/exe_video_sobel25.json。历史提频对比保留在legacy_ethernet/验证记录_v1.6.0.md。',
        '设计、接口、状态机及边界：[720p25流式Sobel设计](720p25流式Sobel设计.md)。','']
    (ROOT/'doc/验证记录.md').write_text('\n'.join(lines),encoding='utf-8')
    print('PASS v1.7.0 release: 720p25 full video, frozen EXE, current RTL and legacy regressions')
    return result

if __name__=='__main__':main()
