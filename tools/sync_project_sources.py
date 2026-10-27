"""Add RTL/memory/testbench references without recreating the user's Vivado project."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
path=ROOT/'project_eth/eth_img.xpr'
original=path.read_bytes()
text=original.decode('utf-8')
backup=ROOT/'tools/backups/before_eth_sources.xpr'
backup.parent.mkdir(parents=True,exist_ok=True)
if not backup.exists(): backup.write_bytes(original)
for fileset,files in [('sources_1', sorted(p for p in (ROOT/'rtl').rglob('*.v') if p.name not in {'uart_img_top.v','uart_rx.v','uart_tx.v'})+sorted((ROOT/'rtl').glob('*.mem')))]:
    match=re.search(r'(<FileSet Name="'+fileset+r'".*?</FileSet>)',text,re.S)
    section=match[1]
    additions=[]
    for file in files:
        reference='$PPRDIR/../'+file.relative_to(ROOT).as_posix()
        if 'Path="'+reference+'"' in section: continue
        attrs=['          <Attr Name="UsedIn" Val="simulation"/>']
        if fileset=='sources_1': attrs[:0]=['          <Attr Name="UsedIn" Val="synthesis"/>','          <Attr Name="UsedIn" Val="implementation"/>']
        if file.suffix=='.mem': attrs[:0]=['          <Attr Name="FileType" Val="Memory Initialization Files"/>']
        additions.append(f'      <File Path="{reference}">\n        <FileInfo>\n'+ '\n'.join(attrs)+'\n        </FileInfo>\n      </File>\n')
    section=section.replace('      <Config>',''.join(additions)+'      <Config>',1)
    text=text[:match.start(1)]+section+text[match.end(1):]
ET.fromstring(text)
if path.read_bytes()!=original: raise RuntimeError('User project changed while syncing')
if text.encode('utf-8')!=original: path.write_text(text,encoding='utf-8',newline='\n')
print('PASS project references synchronized; existing options, runs and constraints preserved')
