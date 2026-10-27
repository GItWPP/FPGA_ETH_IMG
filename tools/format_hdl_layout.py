"""Align explicit ports/declarations and expand compact state declarations; no logic edits."""
from pathlib import Path
import re


def format_source(source):
    expanded=[]
    for line in source.splitlines():
        match=re.fullmatch(r'localparam\s+(.+);',line)
        if match and ',' in match[1]:
            items=[re.fullmatch(r"\s*(\w+)\s*=\s*(\d+)'d(\d+)\s*",p) for p in match[1].split(',')]
            if all(items):
                expanded.extend(f"localparam [{int(m[2])-1}:0] {m[1]:<16} = {m[2]}'d{m[3]};" for m in items)
                continue
        expanded.append(line)
    pattern=re.compile(r'^(\s*)(?:(input|output)\s+)?(wire|reg)\s+(?:(signed)\s+)?(\[[^]]+\]\s+)?(\w+)(.*)$')
    matches=[pattern.fullmatch(line) for line in expanded]
    width=max([8]+[len(m[5].strip())+2 for m in matches if m and m[5]])
    result=[]
    for line,m in zip(expanded,matches):
        if not m:
            result.append(line)
            continue
        indent,io,kind,signed,packed,name,tail=m.groups()
        signed=(signed or '')
        packed=(packed or '').strip()
        if io:
            result.append(f'{indent}{io:<8}{kind:<8}{signed:<7}{packed:<{width}}{name:<23}{tail.strip()}'.rstrip())
        else:
            result.append(f'{indent}{kind:<8}{signed:<7}{packed:<{width}}{name}{tail}'.rstrip())
    return '\n'.join(result)+'\n'


if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]
    files=sorted((root/'rtl').rglob('*.v'))+sorted((root/'sim').glob('*.v'))
    for file in files:
        file.write_text(format_source(file.read_text(encoding='utf-8')),encoding='utf-8')
    print('PASS aligned HDL declarations:',len(files))
