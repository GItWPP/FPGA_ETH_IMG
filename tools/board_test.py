"""Run real FPGA acceptance tests and save returned images plus a JSON report."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
from pathlib import Path
import struct
import time

from PIL import Image
from uart_image import (ImageClient, Packet, ProtocolError, PING, START, DATA, END,
                        image_to_rgb565, open_serial, reference, rgb565_to_image)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=1_500_000)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "board_results")
    args = parser.parse_args()
    out = args.output
    out.mkdir(parents=True, exist_ok=True)
    bit = Path(__file__).resolve().parents[1] / "project_uart" / "build" / "uart_img.bit"
    report = {"time": datetime.now(timezone(timedelta(hours=8))).isoformat(),
              "port": args.port, "baud": args.baud, "status": "running", "transfers": [],
              "bitstream_sha256": hashlib.sha256(bit.read_bytes()).hexdigest() if bit.exists() else None}
    try:
        with open_serial(args.port, args.baud) as stream:
            stream.reset_input_buffer()
            client = ImageClient(stream, args.baud)
            report["ping"] = client.ping().hex(" ")
            print("PASS board PING:", report["ping"], flush=True)
            bad = bytearray(Packet(PING, 0, 5).encode())
            bad[-1] ^= 1
            stream.write(bad)
            if stream.read(4096):
                raise RuntimeError("FPGA unexpectedly replied to bad CRC")
            client.ping()
            stream.write(Packet(PING, 0, 6).encode()[:7])
            time.sleep(0.15)
            if stream.read(4096):
                raise RuntimeError("FPGA unexpectedly replied to truncated packet")
            client.ping()
            report["bad_crc_and_timeout_recovery"] = "PASS"

            tid = 0xCAFE
            client.transact(Packet(START, tid, 0, struct.pack("<HHBB", 2, 1, 1, 1)), 0)
            first = Packet(DATA, tid, 1, b"\x00\xf8")
            one = client.transact(first, 2).payload
            if client.transact(first, 2).payload != one or one != reference(first.payload, 1):
                raise RuntimeError("duplicate block/reference mismatch")
            try:
                client.transact(Packet(DATA, tid, 3, b"\xe0\x07"), 2)
            except ProtocolError as exc:
                if "error 4:" not in str(exc):
                    raise
            else:
                raise RuntimeError("out-of-order DATA was accepted")
            client.transact(Packet(DATA, tid, 2, b"\xe0\x07"), 2)
            client.transact(Packet(END, tid, 3), 0)
            client.transact(Packet(END, tid, 3), 0)
            report["duplicate_and_sequence_recovery"] = "PASS"
            print("PASS board CRC, timeout, duplicate DATA/END and sequence checks", flush=True)

            with Image.open(Path(__file__).parent / "examples" / "test_pattern.png") as image:
                pattern = image.convert("RGB")
            for width, height in ((1, 1), (128, 128), (320, 240)):
                source = pattern.resize((width, height), Image.Resampling.LANCZOS)
                data = image_to_rgb565(source)
                rgb565_to_image(data, width, height).save(out / f"{width}x{height}_source_rgb565.png")
                for mode, name in enumerate(("copy", "gray", "invert")):
                    before_retries = client.retry_count
                    started = time.monotonic()
                    actual = client.transfer(data, width, height, mode)
                    elapsed = time.monotonic() - started
                    expected = reference(data, mode)
                    if actual != expected:
                        offset = next((i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]), -1)
                        raise RuntimeError(f"pixel mismatch: {width}x{height} {name}, offset={offset}, lengths={len(actual)}/{len(expected)}")
                    file = f"{width}x{height}_fpga_{name}.png"
                    rgb565_to_image(actual, width, height).save(out / file)
                    item = {"width": width, "height": height, "mode": name, "bytes": len(actual),
                            "seconds": round(elapsed, 6), "retries": client.retry_count - before_retries,
                            "pixel_compare": "PASS", "image": file,
                            "result_sha256": hashlib.sha256(actual).hexdigest()}
                    report["transfers"].append(item)
                    print(f"PASS board {width}x{height} {name}: {len(actual)} bytes, {elapsed:.3f}s, retries={item['retries']}", flush=True)
            report["total_retries"] = client.retry_count
            report["status"] = "PASS"
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = str(exc)
        raise
    finally:
        (out / "board_test.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("PASS board acceptance; report:", out / "board_test.json", flush=True)


if __name__ == "__main__":
    main()
