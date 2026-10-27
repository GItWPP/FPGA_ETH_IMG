"""Generate real-image and known-bit synthetic FPGA acceptance vectors."""
from pathlib import Path
import json
import numpy as np
from PIL import Image, ImageDraw
from band_reference import decode_integer
from project_paths import user_test_images

ROOT = Path(__file__).resolve().parents[1]


def synthetic(width=256, height=160):
    rng = np.random.default_rng(63719)
    image = Image.new('L', (width, height), 170)
    draw = ImageDraw.Draw(image)
    truth = []
    for row in range(8):
        y, phase = 20+row*16, (row*3+1) % 17
        bits = rng.integers(0, 2, (width-phase+16)//17)
        if row >= 6:
            bits[:] = 1
        for column, x in enumerate(range(phase, width, 17)):
            bit = int(bits[column])
            truth.append((row, x, y, bit))
            if bit:
                draw.ellipse((x-2, y-2, x+2, y+2), fill=40)
    # Independent illumination gradient and deterministic pixel noise.
    values = np.asarray(image, dtype=np.int16)
    values = np.clip(values + np.arange(width)[None, :]//16 + rng.normal(0, 3, values.shape), 0, 255).astype('uint8')
    return values, truth


def main():
    directory = ROOT/'sim/band_vectors'
    directory.mkdir(exist_ok=True)
    images = user_test_images('band')
    originals = []
    for path in images:
        with Image.open(path) as image:
            originals.append((f'sample_{path.stem}', np.asarray(image.convert('L'))))
    original = originals[0][1]
    generated, truth = synthetic()
    cases = originals + [('synthetic', generated),
             ('dim_sample', np.clip(original.astype('int16')-45, 0, 255).astype('uint8')),
             ('blank', np.full((33, 47), 127, dtype='uint8'))]
    metadata = []
    for name, image in cases:
        result = decode_integer(image)
        if name == 'synthetic':
            assert result['status'] == 0
            for word in result['cells']:
                row, x, bit = (word >> 22)&63, word&511, (word >> 18)&1
                target = min((t for t in truth if t[0] == row), key=lambda t: abs(t[1]-x))
                if abs(target[1]-x) <= 3:
                    assert bit == target[3], (word, target)
                else:
                    assert ((word >> 20)&1) and bit == 0, (word, target)
        (directory/f'{name}_gray.mem').write_text(''.join(f'{int(v):02x}\n' for v in image.flat), encoding='ascii')
        (directory/f'{name}_cells.mem').write_text(''.join(f'{v:08x}\n' for v in result['cells']) or '00000000\n', encoding='ascii')
        item = dict(name=name, width=image.shape[1], height=image.shape[0], **{k:v for k,v in result.items() if k != 'cells'})
        item['count'] = len(result['cells'])
        metadata.append(item)
        Image.fromarray(image).save(directory/f'{name}.png')
    (directory/'manifest.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    calls = []
    for item in metadata:
        name = item['name']
        calls.append('run_case("%s", "%s", %d, %d, %d, %d, %d, %d, %d);' % (
            f'../band_vectors/{name}_gray.mem', f'../band_vectors/{name}_cells.mem',
            item['width'], item['height'], item['count'], item['rows'], item['pitch_q8'], item['dots'], item['status']))
    (ROOT/'sim/band_cases.vh').write_text('\n'.join(calls)+'\n', encoding='ascii')
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    main()
