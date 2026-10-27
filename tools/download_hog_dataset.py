"""Download a pinned, documented subset of a public INRIA image mirror."""
from pathlib import Path
import concurrent.futures
import argparse
import hashlib
import json
import random
import re
import ssl
import time
import urllib.request

DATASET = "marcelarosalesj/inria-person"
OUT = Path(__file__).resolve().parent / "datasets" / "inria_hog"
CONTEXT = ssl.create_default_context()


def read(url):
    for attempt in range(6):
        try:
            with urllib.request.urlopen(url, context=CONTEXT, timeout=40) as response:
                return response.read(), response.headers
        except Exception:
            if attempt == 5:
                raise
            time.sleep(1 + attempt * 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--all', action='store_true', help='download the complete pinned mirror')
    parser.add_argument('--revision', default='003a9c033cb85c6b28f512854dcda7e08602616f')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    revision = args.revision
    selected = []
    randomizer = random.Random(20261021)
    for category, count in (("pedestrians", 384), ("no_pedestrians", 128)):
        url = f"https://huggingface.co/api/datasets/{DATASET}/tree/{revision}/data_ped/{category}?limit=1000"
        files = []
        while url:
            data, headers = read(url)
            files.extend(item for item in json.loads(data) if item["type"] == "file" and item["path"].endswith(".png"))
            match = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", ""))
            url = match.group(1) if match else None
        randomizer.shuffle(files)
        chosen = files if args.all else files[:count]
        for item in chosen:
            item["category"] = category
            selected.append(item)
        print(category, "available", len(files), "selected", len(chosen), flush=True)

    def download(item):
        destination = OUT / item["category"] / Path(item["path"]).name
        destination.parent.mkdir(exist_ok=True)
        if not destination.exists():
            data, _ = read(f"https://huggingface.co/datasets/{DATASET}/resolve/{revision}/{item['path']}")
            destination.write_bytes(data)
        payload = destination.read_bytes()
        # Small PNGs are regular Git objects; verify against the pinned tree before using cached files.
        expected = item.get('oid')
        actual = hashlib.sha1(f'blob {len(payload)}\0'.encode()+payload).hexdigest()
        if expected and not item.get('lfs') and actual != expected:
            payload, _ = read(f"https://huggingface.co/datasets/{DATASET}/resolve/{revision}/{item['path']}")
            if hashlib.sha1(f'blob {len(payload)}\0'.encode()+payload).hexdigest() != expected:
                raise RuntimeError(f"Pinned object mismatch: {item['path']}")
            destination.write_bytes(payload)
        return {"category": item["category"], "path": str(destination.relative_to(OUT)).replace("\\", "/"),
                "remote_path": item["path"], "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}

    records = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        for number, record in enumerate(executor.map(download, selected), 1):
            records.append(record)
            if number % 32 == 0:
                print(f"Downloaded/verified {number}/{len(selected)} images", flush=True)
    manifest = {"source": f"https://huggingface.co/datasets/{DATASET}", "revision": revision,
                "original_dataset": "INRIA Person, Dalal and Triggs 2005", "seed": 20261021,
                "selection": "complete pinned mirror; not the official benchmark split" if args.all else "random subset of public mirror; not the official benchmark split",
                "files": records}
    filename = 'source_expanded.json' if args.all else 'source.json'
    (OUT / filename).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("PASS image subset:", len(records), "images", flush=True)


if __name__ == "__main__":
    main()
