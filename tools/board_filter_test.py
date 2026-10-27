"""Verify actual FPGA filters, malformed tiles, retry recovery and native sizes."""
import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
from pathlib import Path
import random
import struct
import time

from PIL import Image
from uart_image import (DATA, END, START, ImageClient, Packet, ProtocolError,
                        image_to_rgb565, iter_filter_tiles, open_serial, reference, rgb565_to_image)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "board_results_filter")
    parser.add_argument("--full-hd", action="store_true", help="also test the worst-latency median mode at 1920x1080")
    parser.add_argument("--modes", type=int, nargs="+", choices=(3, 4, 5, 6, 7), default=(3, 4, 5))
    parser.add_argument("--full-hd-mode", type=int, choices=(3, 4, 5, 6, 7), default=4)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[1]
    bit = root / "project_uart/build/uart_img.bit"
    report = {"status": "running", "port": args.port, "baud": 1500000, "transfers": [],
              "time": datetime.now(timezone(timedelta(hours=8))).isoformat(),
              "bitstream_sha256": hashlib.sha256(bit.read_bytes()).hexdigest()}

    def save():
        (out / "board_filter_test.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    try:
        with open_serial(args.port, 1500000) as stream:
            stream.reset_input_buffer()
            client = ImageClient(stream)
            report["ping"] = client.ping().hex(" ")
            if client.ping()[5] & 0x3F != 0x3F:
                raise RuntimeError("expected original six modes in FPGA capability bitmap")
            print("PASS board filter PING:", report["ping"], flush=True)

            def reject(packet, code):
                try:
                    client.transact(packet, 0)
                except ProtocolError as exc:
                    if f"error {code}:" not in str(exc):
                        raise
                else:
                    raise AssertionError(f"illegal packet was accepted: {packet}")

            # Preserve a successful result across rejected requests and invalid START.
            tid = 0xF117
            data = struct.pack("<169H", *[(i * 701) & 65535 for i in range(169)])
            wanted = reference(data, 4, 169, 1)
            client.transact(Packet(START, tid, 0, struct.pack("<HHBB", 169, 1, 1, 4)), 0)
            for count in (0, 169, 65535):
                reject(Packet(DATA, tid, 1, struct.pack("<H", count) + bytes(18)), 5)
            tiles = list(iter_filter_tiles(data, 169, 1))
            first = Packet(DATA, tid, 1, tiles[0][0])
            actual = client.transact(first, 336).payload
            reject(Packet(DATA, tid, 2, struct.pack("<H", 2) + bytes(24)), 5)
            reject(Packet(START, tid + 1, 0, struct.pack("<HHBB", 1, 1, 1, 8)), 2)
            reject(Packet(DATA, tid, 1, first.payload[:-2]), 6)
            if client.transact(first, 336).payload != actual:
                raise AssertionError("retry did not preserve filtered result")
            actual += client.transact(Packet(DATA, tid, 2, tiles[1][0]), 2).payload
            if actual != wanted:
                raise AssertionError("recovered tile reference mismatch")
            reject(Packet(DATA, tid, 3, struct.pack("<H", 1) + bytes(18)), 5)
            client.transact(Packet(END, tid, 3), 0)
            client.transact(Packet(END, tid, 3), 0)
            report["malformed_tiles_cross_row_conflicting_retry_and_recovery"] = "PASS"
            print("PASS board invalid N/length, row crossing, invalid START, cached retry and frame end", flush=True)
            save()

            with Image.open(root / "tools/examples/test_pattern.png") as source:
                pattern = source.convert("RGB")
            sizes = [(1, 1), (1, 17), (19, 1), (169, 3), (321, 213), (1920, 3), (1, 1080)]
            cases = [(width, height, mode) for width, height in sizes for mode in args.modes]
            if args.full_hd:
                cases.append((1920, 1080, args.full_hd_mode))
            for width, height, mode in cases:
                source = pattern.resize((width, height), Image.Resampling.NEAREST)
                clean = image_to_rgb565(source)
                data = bytearray(clean)
                randomizer = random.Random(0xF117)
                for offset in range(0, len(data), 2):
                    if randomizer.randrange(7) == 0:
                        struct.pack_into("<H", data, offset, 65535 if randomizer.getrandbits(1) else 0)
                data = bytes(data)
                if mode == args.modes[0] or (width, height) == (1920, 1080):
                    rgb565_to_image(clean, width, height).save(out / f"{width}x{height}_clean.png")
                    rgb565_to_image(data, width, height).save(out / f"{width}x{height}_noisy.png")
                retries_before = client.retry_count
                started = time.monotonic()
                last_percent = -1

                def progress(done, total):
                    nonlocal last_percent
                    percent = done * 10 // total
                    if percent != last_percent:
                        report["active_case"] = {"width": width, "height": height, "mode": mode,
                                                 "percent": done * 100 // total}
                        save()
                        if (width, height) == (1920, 1080):
                            print(f"1080p mode {mode}: {done * 100 // total}% at {time.monotonic()-started:.1f}s", flush=True)
                        last_percent = percent

                actual = client.transfer(data, width, height, mode, progress=progress)
                wire_seconds = time.monotonic() - started
                expected = reference(data, mode, width, height)
                if actual != expected:
                    offset = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b), -1)
                    raise AssertionError(f"filter mismatch {width}x{height} mode={mode} byte={offset}")
                name = {3: "mean", 4: "median", 5: "sobel", 6: "gamma", 7: "sharpen"}[mode]
                image = f"{width}x{height}_fpga_{name}.png"
                rgb565_to_image(actual, width, height).save(out / image)
                item = {"width": width, "height": height, "mode": name, "bytes": len(actual),
                        "wire_seconds": round(wire_seconds, 6), "total_seconds": round(time.monotonic() - started, 6),
                        "retries": client.retry_count - retries_before, "compare": "PASS", "image": image,
                        "sha256": hashlib.sha256(actual).hexdigest()}
                report["transfers"].append(item)
                save()
                print(f"PASS board {width}x{height} {name}: {len(actual)} bytes, {wire_seconds:.3f}s, retries={item['retries']}", flush=True)
            report.pop("active_case", None)
            report["status"] = "PASS"
            report["total_retries"] = client.retry_count
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = str(exc)
        raise
    finally:
        save()
    print("PASS board filter acceptance:", out / "board_filter_test.json", flush=True)


if __name__ == "__main__":
    main()
