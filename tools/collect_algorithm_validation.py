"""Require matching 50/125 MHz physical-board measurements and fallback firmware."""
import hashlib
import json
from project_paths import ROOT
from record_build_sources import inputs


def algorithm_comparison(bit_sha):
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()
    def read(relative):
        return json.loads((ROOT/relative).read_text(encoding='utf-8'))
    base = read('tools/board_results_algorithm_clock/baseline50.json')
    fast = read('tools/board_results_algorithm_clock/algorithm125.json')
    assert base['status'] == fast['status'] == 'passed'
    assert (base['algorithm_hz'],fast['algorithm_hz']) == (50_000_000,125_000_000)
    assert fast['bitstream_sha256'] == bit_sha
    fallback_bit = ROOT/'project_eth/build_50mhz/eth_img.bit'
    assert base['bitstream_sha256'] == sha(fallback_bit)
    fallback_inputs = read('project_eth/build_50mhz/build_sources.json')
    assert fallback_inputs['project_eth/ip/clk_wiz_eth/clk_wiz_eth.xci'] == sha(ROOT/'project_eth/build_50mhz/clk_wiz_eth_50mhz.xci')
    current_inputs = inputs()
    for name,digest in fallback_inputs.items():
        if name != 'project_eth/ip/clk_wiz_eth/clk_wiz_eth.xci':
            assert current_inputs[name] == digest, f'Unexpected functional/constraint change: {name}'
    for key in ('image_sha256','raw_sha256','hog_gray_sha256','band_gray_sha256','client_sha256','window','repeat'):
        assert base[key] == fast[key], f'Unmatched benchmark input: {key}'
    assert base['client_sha256'] == sha(ROOT/'tools/eth_image.py')
    assert base['retries'] == fast['retries'] == 0
    assert len(base['image_modes']) == len(fast['image_modes']) == 8
    image_rows = []
    for old,new in zip(base['image_modes'],fast['image_modes']):
        assert (old['name'],old['size'],old['output_sha256']) == (new['name'],new['size'],new['output_sha256'])
        assert len(old['trials']) == len(new['trials']) == fast['repeat']
        image_rows.append(dict(name=new['name'],old_seconds=old['median_seconds'],
                               new_seconds=new['median_seconds'],speedup=old['median_seconds']/new['median_seconds']))
    summary = dict(status='passed',baseline_bitstream_sha256=base['bitstream_sha256'],bitstream_sha256=bit_sha,
                   image_modes=image_rows,hog_run_speedup=base['hog_run_median_seconds']/fast['hog_run_median_seconds'],
                   band_run_speedup=base['band_run_median_seconds']/fast['band_run_median_seconds'])
    (ROOT/'tools/board_results_algorithm_clock/comparison.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    lines = ['', '## 算法50MHz与125MHz同板对比', '',
             '- 同一块板、同一客户端、同一32包窗口，分别下载50MHz和125MHz固件；每项测量5次，取中位数，图像/HOG另有一次不计时预热。两版RTL、ROM和XDC哈希完全相同，仅Clocking Wizard配置变化。',
             '- 图片编码和独立参考计算在计时外，结果逐字节/逐项一致，两版均零重传。RUN命令耗时包含该命令的UDP往返；完整事务另含上传、应答和结果回读。', '',
             '| 指标 | 50MHz/ms | 125MHz/ms | 加速倍数 |', '| --- | --- | --- | --- |']
    for label,key in (('HOG RUN','hog_run_median_seconds'),('HOG完整事务','hog_median_seconds'),
                      ('Band RUN','band_run_median_seconds'),('Band完整事务','band_median_seconds')):
        lines.append(f'| {label} | {base[key]*1000:.3f} | {fast[key]*1000:.3f} | {base[key]/fast[key]:.2f}× |')
    for row in image_rows:
        lines.append(f'| 640×360 {row["name"]}完整事务 | {row["old_seconds"]*1000:.3f} | {row["new_seconds"]*1000:.3f} | {row["speedup"]:.2f}× |')
    lines += ['', '- 50MHz回退文件：运行包中的eth_img_algo50.bit，来源project_eth/build_50mhz/eth_img.bit；对应XCI、构建输入和时序记录均保留。',
              '- 默认构建：tools/build.ps1 -AlgorithmMHz 125；回退重建：tools/build.ps1 -AlgorithmMHz 50。描述符FIFO及独立算法端口均保留。',
              '- 纯计算的理论上限为2.5倍；图像完整事务和视频FPS受传输与上位机影响，按本次实测记录。', '']
    return lines,summary
