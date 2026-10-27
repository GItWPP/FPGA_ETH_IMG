"""Check the publishable project, ROM consistency and canonical test fixtures."""
from pathlib import Path
import json
import re
import struct
import subprocess
import xml.etree.ElementTree as ET
import zlib
from PIL import Image
from hog_model import MODEL_ID, WEIGHTS, BIAS
from project_paths import ROOT, user_test_image, user_test_images


def main():
    project=ROOT/'project_eth/eth_img.xpr'
    tree=ET.parse(project)
    assert tree.find(".//Option[@Name='Part']").attrib['Val']=='xczu4ev-sfvc784-2-i'
    references=[]
    for fileset in ['sources_1','constrs_1','sim_1']:
        for item in tree.findall(f".//FileSet[@Name='{fileset}']/File"):
            raw=item.attrib['Path']
            assert raw.startswith('$PPRDIR/'),raw
            path=(project.parent/raw.removeprefix('$PPRDIR/')).resolve()
            assert path.is_relative_to(ROOT.resolve()) and path.is_file(),raw
            references.append(path)
    legacy={'uart_img_top.v','uart_rx.v','uart_tx.v'}
    assert {p for p in (ROOT/'rtl').rglob('*.v') if p.name not in legacy} <= set(references)
    assert not any(p.name in legacy for p in references),'UART physical layer must not enter ZU4EV synthesis'
    assert not tree.findall(".//FileSet[@Name='utils_1']/File"),'Local DCP must not be required'
    clock=json.loads((ROOT/'project_eth/ip/clk_wiz_eth/clk_wiz_eth.xci').read_text())
    parameters=clock['ip_inst']['parameters']['component_parameters']
    assert float(parameters['PRIM_IN_FREQ'][0]['value'])==125
    assert float(parameters['CLKOUT1_REQUESTED_OUT_FREQ'][0]['value'])==125
    assert float(parameters['CLKOUT2_REQUESTED_OUT_FREQ'][0]['value']) in (50,125)
    assert float(parameters['CLKOUT3_REQUESTED_OUT_FREQ'][0]['value'])==125
    assert float(parameters['CLKOUT3_REQUESTED_PHASE'][0]['value'])==0
    assert not re.search(r'set_clock_groups', (ROOT/'eth_cdc.xdc').read_text()),'Do not blanket-cut CDC domains'
    values=[int(line,16) for line in (ROOT/'rtl/hog_svm_weights.mem').read_text().split()]
    values=[value-65536 if value>=32768 else value for value in values]
    assert values==list(WEIGHTS),'Python and RTL weights differ'
    assert zlib.crc32(struct.pack('<i3780h',BIAS,*WEIGHTS))==MODEL_ID,'Model ID differs'
    pictures=[]
    for path in user_test_images():
        with Image.open(path) as image:
            image.verify()
        pictures.append(path.name)
    assert all(path in user_test_images() for group in ('band','hog','image') for path in user_test_images(group))
    assert user_test_image('1.png').is_file()
    bits=(ROOT/'test_img/expected/band_1_bits.txt').read_text().splitlines()
    assert len(bits)==19 and sum(map(len,bits))==575 and all(set(row)<={'0','1'} for row in bits)
    listed=subprocess.run(['git','-C',str(ROOT),'ls-files','-z'],capture_output=True,check=False)
    names=listed.stdout.decode('utf-8').split('\0') if listed.returncode==0 else []
    names=[name for name in names if name]
    for name in names:
        path=ROOT/name
        assert not any(part in {'datasets','training_cache','.packaging_venv','backups','__pycache__'} for part in path.parts),name
        assert path.suffix.lower() not in {'.exe','.bit','.dcp','.wdb','.log','.jou','.pem','.key','.pfx'},name
        if path.suffix in {'.py','.ps1','.tcl','.v','.vh'}:
            text=path.read_text(encoding='utf-8')
            # Match a concrete drive path only; configurable Vivado installation defaults are allowed.
            assert not re.search(r'[A-Za-z]:[/\\](?:Users[/\\]hp|FPGA_SERVO_DESIGN)',text),name
        if path.suffix.lower() in {'.py','.ps1','.tcl','.v','.md','.json','.yml','.yaml','.xpr'}:
            text=path.read_text(encoding='utf-8')
            assert not re.search(r'gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----',text),f'Possible credential in {name}'
    print(json.dumps(dict(status='passed',source_references=len(references),test_images=pictures,
                          hog_model=f'{MODEL_ID:08X}',tracked_files=len(names)),ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
