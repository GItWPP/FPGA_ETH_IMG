"""Bind a bitstream build to exact RTL, memory and constraint input hashes."""
import argparse
import hashlib
import json
from pathlib import Path
from project_paths import ROOT


def inputs():
    paths = sorted((ROOT/'rtl').rglob('*.v')) + sorted((ROOT/'rtl').rglob('*.mem'))
    paths += [ROOT/'eth_img.xdc', ROOT/'eth_cdc.xdc', ROOT/'project_eth/ip/clk_wiz_eth/clk_wiz_eth.xci']
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--check',type=Path)
    args = parser.parse_args()
    if args.check:
        saved = json.loads(args.check.read_text(encoding='utf-8'))
        assert saved == inputs(), 'Build inputs changed; rebuild the bitstream'
        print('PASS bitstream source hashes match current inputs')
    else:
        args.output.write_text(json.dumps(inputs(),indent=2)+'\n',encoding='utf-8')
        print('PASS captured exact bitstream build input hashes')


if __name__ == '__main__':
    main()
