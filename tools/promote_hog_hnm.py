"""Activate the frozen, evaluated HNM candidate without recreating the Vivado project."""
from pathlib import Path
import hashlib
import json
import shutil
import struct
import zlib
from train_hog_hnm import load_baseline

root=Path(__file__).resolve().parents[1]
candidate=root/'tools/model_candidates/hog_hnm_v2'
manifest=json.loads((candidate/'hog_model_manifest.json').read_text(encoding='utf-8'))
old=manifest['independent_test']['baseline']
new=manifest['independent_test']['new_quantized']
assert manifest['selected_round']>=1
assert new['background_false_boxes_per_image_at_zero']<old['background_false_boxes_per_image_at_zero']
assert new['positive_recall_at_zero']>=old['positive_recall_at_zero']-0.05
assert manifest['positive_quantization_disagreements']==0 and manifest['positive_quantization_disagreements_at_zero']==0
negative_windows=manifest['quantized_validation_metrics']['negative_windows']
assert max(manifest['negative_quantization_disagreements'],manifest['negative_quantization_disagreements_at_zero'])/negative_windows<=0.0001
model=load_baseline(candidate/'hog_model.py')
packed=struct.pack('<i',model.BIAS)+struct.pack('<3780h',*model.WEIGHTS)
assert f'{zlib.crc32(packed):08X}'==manifest['model_id']
assert hashlib.sha256(packed).hexdigest()==manifest['weights_sha256']
history=root/'tools/model_versions/hog_D2A8B58B'
for name in ['hog_validation_scene.png','hog_frame.mem']:
    if not (history/name).exists(): shutil.copy2(root/'sim'/name,history/name)
destinations={'hog_model.py':'tools/hog_model.py','hog_svm_model.v':'rtl/hog_svm_model.v',
              'hog_svm_weights.mem':'rtl/hog_svm_weights.mem','hog_model_manifest.json':'doc/hog_model_manifest.json',
              'hog_validation_scene.png':'sim/hog_validation_scene.png','hog_frame.mem':'sim/hog_frame.mem'}
for name,relative in destinations.items(): shutil.copy2(candidate/name,root/relative)
print('PASS activated evaluated model',manifest['model_id'],'default threshold',model.DEFAULT_THRESHOLD)
