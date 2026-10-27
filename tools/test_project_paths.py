import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from project_paths import user_test_image, user_test_images


class ProjectPathTests(unittest.TestCase):
    def test_current_manifest_and_all_images(self):
        self.assertEqual([p.name for p in user_test_images('band')], ['1.png','2.png','3.png','4.png'])
        self.assertTrue(set(user_test_images('band')+user_test_images('hog')) <= set(user_test_images()))

    def test_missing_picture_has_clear_error(self):
        with self.assertRaisesRegex(FileNotFoundError,'test_img'):
            user_test_image('missing_fixture.png')

    def test_absolute_paths_and_parent_traversal_rejected(self):
        for name in ['../README.md', str(Path(__file__).resolve())]:
            with self.assertRaises(ValueError):
                user_test_image(name)

    def test_relocated_image_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve()
            (root/'picture.png').write_bytes(b'fixture')
            (root/'manifest.json').write_text(json.dumps({'groups':{'band':['picture.png']}}))
            with patch('project_paths.TEST_IMAGES',root):
                self.assertEqual(user_test_image('picture.png'),root/'picture.png')
                self.assertEqual(user_test_images('band'),[root/'picture.png'])
