"""Physical-board Band acceptance with exact integer-reference comparisons."""
from pathlib import Path
import argparse
import hashlib
import json
import time
import struct
import numpy as np
from PIL import Image
from uart_image import ImageClient, open_serial, ProtocolError, Packet
from band_client import BandClient, prepare_band, draw_band, export_band
from band_reference import decode_integer
from generate_band_vectors import synthetic
from project_paths import user_test_images


class RetryProbe(ImageClient):
    def __init__(self, stream):
        super().__init__(stream)
        self.probed = set()

    def transact(self, packet, expected_length, **kwargs):
        answer = super().transact(packet, expected_length, **kwargs)
        if packet.cmd in (0x21, 0x22, 0x23) and packet.cmd not in self.probed:
            repeat = super().transact(packet, expected_length, **kwargs)
            assert repeat == answer, ('duplicate response', packet.cmd)
            self.probed.add(packet.cmd)
        return answer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', default='COM11')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = root/'tools/board_results_band'
    out.mkdir(exist_ok=True)
    report = dict(status='running', port=args.port, frames=[])
    candidate = root/'project_uart/build/uart_img.bit'
    report['bitstream_sha256'] = hashlib.sha256(candidate.read_bytes()).hexdigest()
    save = lambda: (out/'board_band_test.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    try:
        with open_serial(args.port, 1500000) as stream:
            stream.reset_input_buffer()
            client = RetryProbe(stream)
            decoder = BandClient(client)
            report['info'] = decoder.info().hex()
            cases=[]
            for path in user_test_images('band'):
                with Image.open(path) as image:
                    cases.append((f'sample_{path.stem}', image.convert('L')))
            generated,_=synthetic()
            original=np.asarray(cases[0][1]).astype('int16')
            cases.extend([('synthetic', Image.fromarray(generated)),
                          ('dim_sample', Image.fromarray(np.clip(original-45,0,255).astype('uint8'))),
                          ('blank', Image.new('L',(47,33),127))])
            for index, (name, image) in enumerate(cases):
                expected = decode_integer(np.asarray(image))
                start = time.monotonic()
                if expected['status']:
                    try:
                        decoder.decode(prepare_band(image), *image.size, transfer_id=2300+index)
                    except ProtocolError as exc:
                        assert '未找到有效数据带' in str(exc), str(exc)
                    else:
                        raise AssertionError('blank image accepted as data')
                    report['frames'].append(dict(name=name, rejected_status=expected['status']))
                else:
                    result = decoder.decode(prepare_band(image), *image.size, transfer_id=2300+index)
                    assert result.words == expected['cells'], (name, [(i, a, b) for i, (a, b) in enumerate(zip(result.words, expected['cells'])) if a != b][:5])
                    assert (result.rows, result.pitch_q8, result.detected_dots) == (expected['rows'], expected['pitch_q8'], expected['dots'])
                    export_band(draw_band(image, result), result, out/f'{name}.png')
                    report['frames'].append(dict(name=name, cells=len(result.words), data_bits=sum(map(len, result.binary_rows())),
                        data_rows=result.rows-2, uart_seconds=time.monotonic()-start, run_command_seconds=result.calculation_seconds))
                print('PASS board Band', report['frames'][-1], flush=True)
                save()
            # A saturated point list must reject the frame, rather than return truncated data.
            dense = np.full((512, 512), 170, dtype='uint8')
            dense[4::8, 4::8] = 20
            try:
                decoder.decode(dense.tobytes(), 512, 512, transfer_id=2310)
            except ProtocolError as exc:
                assert '缓存溢出' in str(exc), str(exc)
            else:
                raise AssertionError('point-list overflow accepted')
            report['overflow_rejection'] = 'passed'
            # Invalid commands from another algorithm preserve the last successful cached result.
            image = Image.fromarray(generated)
            result = decoder.decode(prepare_band(image), *image.size, transfer_id=2320)
            read = Packet(0x23, 2320, 42, struct.pack('<HH', 0, len(result.words)))
            expected_payload = struct.pack(f'<{len(result.words)}I', *result.words)
            def reject(packet, error):
                try:
                    client.transact(packet, 0)
                except ProtocolError as exc:
                    assert f'error {error}:' in str(exc), str(exc)
                else:
                    raise AssertionError('invalid command accepted')
            reject(Packet(2, 2400, 0), 2)
            assert client.transact(read, len(expected_payload)).payload == expected_payload
            reject(Packet(0x23, 2320, 43, struct.pack('<HH', 120, 2)), 2)
            assert client.transact(read, len(expected_payload)).payload == expected_payload
            client.transact(Packet(2, 2400, 0, struct.pack('<HHBB', 1, 1, 1, 0)), 0)
            pixel = Packet(3, 2400, 1, bytes.fromhex('12ab'))
            assert client.transact(pixel, 2).payload == pixel.payload
            reject(Packet(0x2e, 2401), 1)
            reject(Packet(0x20, 2401, 0, struct.pack('<HH', 15, 32)), 2)
            assert client.transact(pixel, 2).payload == pixel.payload
            client.transact(Packet(0x20, 2401, 0, struct.pack('<HH', 16, 16)), 0)
            reject(Packet(3, 2400, 2, pixel.payload), 3)
            report['cross_algorithm_cache_and_sessions'] = 'passed'
            report.update(status='passed', retry_count=client.retry_count, duplicate_commands_tested=sorted(client.probed))
    except Exception as exc:
        report.update(status='failed', error=repr(exc))
        save()
        raise
    save()


if __name__ == '__main__':
    main()
