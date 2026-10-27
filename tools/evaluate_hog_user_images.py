"""Reproduce user photographs under archived/current candidate models; never train on them."""
from pathlib import Path
import argparse
import hashlib
import json
from PIL import Image
from train_hog_hnm import load_baseline
from hog_client import prepare_hog,map_boxes,draw_detections
from hog_reference import detect_reference
from project_paths import user_test_images


def main():
    root=Path(__file__).resolve().parents[1]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,default=root/'tools')
    parser.add_argument('--output',type=Path,default=root/'tools/board_results_hog/user_images')
    args=parser.parse_args()
    output=args.output
    output.mkdir(parents=True,exist_ok=True)
    models=[('baseline',root/'tools/model_versions/hog_D2A8B58B/hog_model.py'),('new',args.candidate/'hog_model.py')]
    report={'usage':'Application regression only, excluded from training, mining and model/threshold selection. Candidate counts are not precision/recall measurements.','cases':[]}
    for path in user_test_images('hog'):
        name=path.name
        image=Image.open(path).convert('RGB')
        gray,geometry=prepare_hog(image)
        result={'image':name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'size':list(image.size),'models':{}}
        for label,source in models:
            model=load_baseline(source)
            scores=detect_reference(gray,model.WEIGHTS,model.BIAS)
            thresholds=[0,0.5,1.0,getattr(model,'DEFAULT_THRESHOLD',0)]
            records={}
            for threshold in sorted(set(thresholds)):
                raw_threshold=round(threshold*(1<<22))
                records[str(threshold)]=map_boxes(scores,geometry,raw_threshold)
                annotated,_=draw_detections(image,scores,geometry,raw_threshold)
                annotated.save(output/f'{Path(name).stem}_{label}_threshold_{threshold}.png')
            result['models'][label]={'model_id':f'{model.MODEL_ID:08X}','max_score':max(scores)/(1<<22),
                                    'threshold_boxes':records,'scores':scores}
        report['cases'].append(result)
    (output/'user_regression.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print([(r['image'],{label:{t:len(boxes) for t,boxes in m['threshold_boxes'].items()} for label,m in r['models'].items()}) for r in report['cases']],flush=True)


if __name__=='__main__': main()
