"""Resolve all repository test pictures from the canonical test_img directory."""
from pathlib import Path
import json

ROOT=Path(__file__).resolve().parents[1]
TEST_IMAGES=ROOT/'test_img'


def user_test_image(name):
    path=(TEST_IMAGES/name).resolve()
    if path.parent != TEST_IMAGES.resolve():
        raise ValueError('Test image names must refer directly to test_img')
    if not path.is_file():
        raise FileNotFoundError(f'Cannot find test_img/{name}')
    return path


def user_test_images(group=None):
    if group is not None:
        manifest=json.loads((TEST_IMAGES/'manifest.json').read_text(encoding='utf-8'))
        return [user_test_image(name) for name in manifest['groups'][group]]
    return sorted((p for p in TEST_IMAGES.iterdir() if p.suffix.lower() in
                   ('.png','.jpg','.jpeg','.bmp','.tif','.tiff','.webp')),key=lambda p:p.name.casefold())
