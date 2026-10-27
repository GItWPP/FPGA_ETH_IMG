"""Check the project's explicit HDL layout rules (not a functional HDL linter)."""
from pathlib import Path
import re


def main():
    root = Path(__file__).resolve().parents[1]
    failures = []
    files = sorted((root / "rtl").rglob("*.v")) + sorted((root / "sim").glob("*.v"))
    for file in files:
        text = file.read_text(encoding="utf-8")
        module = re.search(r"\bmodule\s+(\w+)", text)
        if module is None:
            failures.append(f"{file.name}: missing module")
            continue
        intro = text.split("`timescale", 1)[0]
        for field in ("模块", "Type", "Standard", "功能", "作者", "时间"):
            if field not in intro:
                failures.append(f"{file.name}: missing header field {field}")
        if module.group(1) not in intro:
            failures.append(f"{file.name}: header does not name module")
        for section in ("Parameter and Internal Signal", "Main Code"):
            if section not in text:
                failures.append(f"{file.name}: missing {section} section")
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("//", 1)[0].strip()
            if not code:
                continue
            if len(re.findall(r"\.\w+\s*\(", code)) > 1:
                failures.append(f"{file.name}:{number}: multiple named port/parameter mappings on one line")
            if not code.startswith("for(") and re.search(r";\s*\S", code):
                failures.append(f"{file.name}:{number}: multiple statements on one line")
            # Function/task arguments end in semicolons and use variable types,
            # while ANSI module ports must explicitly declare wire/reg.
            words = code.split()
            if words[0] in ("input", "output") and not code.endswith(";") and words[1] not in ("wire", "reg"):
                failures.append(f"{file.name}:{number}: port lacks explicit wire/reg")
            if re.match(r"wire\s+.*=", code):
                failures.append(f"{file.name}:{number}: move net assignment into Main Code")
    for failure in failures:
        print(failure)
    if failures:
        return 1
    print(f"PASS HDL layout: {len(files)} files; headers, sections, explicit ports, one mapping/statement per line")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
