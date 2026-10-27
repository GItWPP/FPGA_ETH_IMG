"""Preserve the deployed model/build and user-image score baselines before retraining."""
from pathlib import Path
import hashlib
import json
import shutil
from PIL import Image
from hog_model import MODEL_ID,SCORE_SHIFT
from hog_client import prepare_hog,map_boxes
from hog_reference import detect_reference
from project_paths import user_test_images

root=Path(__file__).resolve().parents[1]
out=root/f'tools/model_versions/hog_{MODEL_ID:08X}'
out.mkdir(parents=True,exist_ok=True)
for relative in ['tools/hog_model.py','rtl/hog_svm_model.v','rtl/hog_svm_weights.mem','doc/hog_model_manifest.json',
                 'tools/train_hog_model.py','tools/hog_training.log','tools/board_results_hog/board_hog_test.json']:
    source=root/relative
    destination=out/source.name
    if source.exists() and not destination.exists(): shutil.copy2(source,destination)
build=root/f'project_uart/build/baseline_{MODEL_ID:08X}'
build.mkdir(exist_ok=True)
for name in ['uart_img.bit','timing_summary.rpt','utilization.rpt','drc.rpt','build_summary.txt']:
    if not (build/name).exists(): shutil.copy2(root/'project_uart/build'/name,build/name)
results=[]
for path in user_test_images('hog'):
    name=path.name
    image=Image.open(path).convert('RGB')
    gray,geometry=prepare_hog(image)
    scores=detect_reference(gray)
    counts={str(t):len(map_boxes(scores,geometry,round(t*(1<<SCORE_SHIFT)))) for t in (0,0.5,1.0)}
    results.append({'file':name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'size':list(image.size),
                    'scores':scores,'candidate_counts':counts,'max_score':max(scores)/(1<<SCORE_SHIFT)})
(out/'user_image_baseline.json').write_text(json.dumps({'model_id':f'{MODEL_ID:08X}','cases':results},indent=2),encoding='utf-8')
print('PASS baseline archived:',out)
print([(r['file'],r['candidate_counts']) for r in results])
