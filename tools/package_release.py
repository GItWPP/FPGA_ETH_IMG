"""Package the tested ZU4EV executable, bitstream, pictures and portable source."""
from pathlib import Path
import argparse
from datetime import date
import hashlib
import json
import shutil
import re
import zipfile
from PIL import Image
from hog_model import MODEL_ID
from project_paths import ROOT, user_test_images


def source_files():
    selected=set()
    for folder in ('rtl','sim','tools'):
        selected.update(p for p in (ROOT/folder).glob('*.py'))
        selected.update(p for p in (ROOT/folder).glob('*.ps1'))
        selected.update(p for p in (ROOT/folder).glob('*.tcl'))
        selected.update(p for p in (ROOT/folder).glob('requirements*.txt'))
    selected.update(p for p in (ROOT/'tools/native').rglob('*') if p.is_file() and p.suffix in ('.c','.dll','.ps1','.json'))
    selected.update((ROOT/'rtl').rglob('*.v'))
    selected.update((ROOT/'rtl').rglob('*.mem'))
    selected.update((ROOT/'sim').glob('tb_*.v'))
    selected.update((ROOT/'tools/model_versions').rglob('*.py'))
    selected.update(p for p in (ROOT/'doc').rglob('*') if p.is_file() and p.suffix in ('.md','.xdc'))
    selected.update(p for p in (ROOT/'doc/images').glob('*.png'))
    selected.update(p for p in (ROOT/'test_img').rglob('*') if p.is_file())
    selected.update(ROOT/'test_video'/name for name in ('fpga_demo_25.mp4','fpga_demo_25.json','README.md'))
    selected.update((ROOT/'.github').rglob('*.yml'))
    selected.update(ROOT/name for name in ('README.md','.gitignore','.gitattributes','eth_img.xdc','eth_cdc.xdc'))
    selected.add(ROOT/'project_eth/eth_img.xpr')
    selected.add(ROOT/'project_eth/ip/clk_wiz_eth/clk_wiz_eth.xci')
    return sorted(selected,key=lambda p:p.relative_to(ROOT).as_posix())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag',default='v1.7.0')
    args=parser.parse_args()
    if not args.tag.startswith('v') or any(c not in 'v0123456789.-' for c in args.tag):
        parser.error('Use a version tag such as v1.0.0')
    # Refuse to label stale/new binaries as tested using old board reports.
    from collect_validation import main as validate_artifacts
    validate_artifacts()
    project=ROOT/'project_eth/eth_img.xpr'
    project_text=project.read_text(encoding='utf-8')
    portable=re.sub(r'(<Project\b[^>]*\bPath=")[^"]*(")',r'\1eth_img.xpr\2',project_text,count=1)
    if portable!=project_text:
        project.write_text(portable,encoding='utf-8')
    out=ROOT/'tools/dist'/f'FPGA_ETH_IMG-ZU4EV-{args.tag}'
    out.mkdir(parents=True,exist_ok=True)
    sources=[(ROOT/'tools/dist/ETH_Image_ZU4EV.exe','ETH_Image_ZU4EV.exe'),
             (ROOT/'project_eth/build/eth_img.bit','eth_img.bit'),
             (ROOT/'project_eth/build/build_sources.json','build_sources.json'),
             (ROOT/'project_eth/build_50mhz/eth_img.bit','eth_img_algo50.bit'),
             (ROOT/'project_eth/build_50mhz/build_sources.json','build_sources_algo50.json'),
             (ROOT/'project_eth/build_50mhz/build_summary.txt','build_summary_algo50.txt'),
             (ROOT/'project_eth/build_50mhz/clk_wiz_eth_50mhz.xci','clk_wiz_eth_algo50.xci')]
    artifacts=[]
    for source,name in sources:
        if not source.is_file():
            raise FileNotFoundError(f'Build the runtime artifact first: {source.relative_to(ROOT)}')
        target=out/name
        shutil.copy2(source,target)
        artifacts.append(dict(name=target.name,bytes=target.stat().st_size,sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
    images=[]
    for path in user_test_images():
        with Image.open(path) as image:
            size=list(image.size)
        images.append(dict(path=path.relative_to(ROOT).as_posix(),size=size,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    files=source_files()
    source_hashes=[dict(path=p.relative_to(ROOT).as_posix(),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in files]
    fingerprint=hashlib.sha256(json.dumps(source_hashes,sort_keys=True,separators=(',',':')).encode('utf-8')).hexdigest()
    source_zip=out.parent/f'{out.name}-source.zip'
    with zipfile.ZipFile(source_zip,'w',zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path,'FPGA_ETH_IMG/'+path.relative_to(ROOT).as_posix())
    shutil.copytree(ROOT/'test_img',out/'test_img',dirs_exist_ok=True)
    # Ship the managed fixture, leaving arbitrary user-loaded videos in place.
    video_out=(out/'test_video').resolve()
    assert out.resolve().is_relative_to((ROOT/'tools/dist').resolve())
    assert video_out.parent==out.resolve() and video_out.name=='test_video'
    if video_out.exists():
        shutil.rmtree(video_out)
    video_out.mkdir()
    for name in ('fpga_demo_25.mp4','fpga_demo_25.json','README.md'):
        shutil.copy2(ROOT/'test_video'/name,video_out/name)
    instructions=out/'使用说明.txt'
    speed=json.loads((ROOT/'tools/board_results_eth_throughput/throughput.json').read_text())
    instructions.write_text(f'''ZU4EV 千兆以太网图像工作台
1. 必须同时使用本版ETH_Image_ZU4EV.exe和eth_img.bit，视频Sobel新增流式协议；传输及算法域均125MHz。
2. 网线连接ADC_ETH使用的PL千兆网口；电脑IPv4为192.168.1.18/24。
3. 双击ETH_Image_ZU4EV.exe，板卡IP 192.168.1.12，UDP端口1234。
4. 打开test_img中的图片发送处理；Band使用1.png～4.png，底部两行同步点排除。
5. 预览支持滚轮缩放、拖动和双击适应窗口；Band可查看并导出二进制。
6. 点击“打开视频”，选择图像算法或HOG、视频处理尺寸及播放策略，然后“开始播放”。
7. 视频支持暂停、继续、停止、重新播放和保存当前帧；默认实时策略会跳过旧帧保持低延迟。
8. test_video/fpga_demo_25.mp4为1280×720、25FPS、6秒样例。选择Sobel边缘检测、原视频尺寸和逐帧处理即可使用新通道。
9. 新通道由FPGA完成亮度、两行缓存与Sobel，上传RGB565、回传GRAY8，64包窗口；EXE内置Windows批量UDP收发模块，无需安装编译器。
请使用同版本EXE与bitstream。完整源码、独立Vivado工程和说明位于同版本-source.zip。
该bitstream为易失JTAG配置。普通图像默认32包窗口、最多64包，收发流水线并行工作，五次全高清复制往返中位耗时{speed['seconds']:.3f}秒，单图有效吞吐{speed['useful_image_Mbps']:.2f} Mbps。
上位机分别显示网络传输速度与含图片转换和校验的总耗时。HOG/Band命令仍为单包事务。
链路为1 Gbps；RGMII外部I/O delay仍需依据板级PHY/PCB参数补齐签核。
如需回退算法50MHz，下载eth_img_algo50.bit；该文件为历史v1.5固件，只支持旧算法协议，不支持本版视频流式Sobel；配套构建记录和旧XCI单独保留。
''',encoding='utf-8')
    build=dict(line.split('=',1) for line in (ROOT/'project_eth/build/build_summary.txt').read_text().splitlines())
    python_log=(ROOT/'tools/board_results/python_tests.log').read_text(encoding='utf-8')
    python_tests=int(re.search(r'Ran (\d+) tests',python_log)[1])
    manifest=dict(project='FPGA_ETH_IMG',tag=args.tag,date=date.today().isoformat(),
                  source_fingerprint=fingerprint,source_files=source_hashes,
                  source_archive=dict(name=source_zip.name,sha256=hashlib.sha256(source_zip.read_bytes()).hexdigest()),
                  fpga_part='xczu4ev-sfvc784-2-i',app_clock_hz=125000000,algorithm_clock_hz=125000000,gmii_clock_hz=125000000,
                  local_mac='02:55:49:4D:47:04',local_ip='192.168.1.12',udp_port=1234,link_bps=1000000000,
                  hog_model=f'{MODEL_ID:08X}',artifacts=artifacts,test_images=images,
                  timing=dict(setup_slack_ns=float(build['SETUP_SLACK_NS']),hold_slack_ns=float(build['HOLD_SLACK_NS']),external_rgmii_io_signoff=False),
                  transport=dict(data_window=32,max_data_window=64,rx_packet_slots=64,tx_packet_slots=8,
                                 receive_banks=2,response_fifo_depth=8,result_cache_slots=64,physical_cache_slots=65,
                                 algorithm_cdc='three asynchronous descriptor FIFOs and two dual-clock RAMs',
                                 band_frame_memory="UltraRAM",band_frame_uram_tiles=8,
                                 full_hd_seconds=speed['seconds'],useful_image_Mbps=speed['useful_image_Mbps']),
                  host_optimization=json.loads((ROOT/'tools/board_results_host/optimized.json').read_text(encoding='utf-8')),
                  stream_sobel=json.loads((ROOT/'tools/board_results_stream/release_acceptance.json').read_text(encoding='utf-8')),
                  native_udp=dict(dll_sha256=hashlib.sha256((ROOT/'tools/native/stream_udp.dll').read_bytes()).hexdigest(),
                                  embedded_in_exe=True,window=64),
                  fallback=dict(algorithm_clock_hz=50000000,bitstream='eth_img_algo50.bit',
                                bitstream_sha256=hashlib.sha256((ROOT/'project_eth/build_50mhz/eth_img.bit').read_bytes()).hexdigest()),
                  video=json.loads((ROOT/'tools/board_results_stream/all.json').read_text())['video'],
                  validation=dict(python_tests=python_tests,rtl_self_checks=20,gmii_transactions=396,stream_protocol_replies=155,
                                  board='Current images and video, injected UDP loss/reorder, and seven frozen GUI modes including complete 720p25 Sobel and video playback controls verified on the physical ZU4EV board.'))
    metadata=out/'release_manifest.json'
    metadata.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    checksums=[(item['name'],item['sha256']) for item in artifacts]
    checksums.append((metadata.name,hashlib.sha256(metadata.read_bytes()).hexdigest()))
    checksums.append((instructions.name,hashlib.sha256(instructions.read_bytes()).hexdigest()))
    checksums.extend((item['path'],item['sha256']) for item in images)
    checksums.extend((p.relative_to(out).as_posix(),hashlib.sha256(p.read_bytes()).hexdigest())
                     for p in (out/'test_video').rglob('*') if p.is_file())
    (out/'SHA256SUMS.txt').write_text(''.join(f'{digest}  {name}\n' for name,digest in checksums),encoding='utf-8')
    runtime_zip=Path(shutil.make_archive(str(out),'zip',root_dir=out.parent,base_dir=out.name))
    print(out)
    print(runtime_zip)
    print(source_zip)


if __name__=='__main__':
    main()
