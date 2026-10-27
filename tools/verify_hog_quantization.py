"""Check exported integer scores against the frozen float model at both operating points."""
from pathlib import Path
import json
import numpy as np
from threadpoolctl import threadpool_limits
from train_hog_hnm import evaluation,make_base,load_baseline,DATA

root=Path(__file__).resolve().parents[1]
candidate=root/'tools/model_candidates/hog_hnm_v2'
manifest=json.loads((candidate/'hog_model_manifest.json').read_text(encoding='utf-8'))
items={i['path']:i for i in json.loads((DATA/'source_expanded.json').read_text())['files']}
files=[items[path] for path in manifest['validation_images']]
cache=root/'tools/training_cache/hog_integer_v1'
model=load_baseline(candidate/'hog_model.py')
with np.load(candidate/'floating_model.npz') as data:
    weights,bias,threshold=data['weights'],float(data['bias'][0]),float(data['threshold'])
with threadpool_limits(limits=4):
    _,_,positive,_=make_base([i for i in files if i['category']=='pedestrians'],cache,False,np.random.default_rng(1))
    _,qp,qn=evaluation(files,positive,None,None,cache,threshold,quantized=(model.WEIGHTS,model.BIAS))
    _,fp,fn=evaluation(files,positive,weights,bias,cache,threshold)
counts={}
for suffix,point in [('',threshold),('_at_zero',0)]:
    counts['positive_quantization_disagreements'+suffix]=int(np.count_nonzero((qp>point)!=(fp>point)))
    counts['negative_quantization_disagreements'+suffix]=int(np.count_nonzero((qn>point)!=(fn>point)))
maximum_error=float(max(np.max(np.abs(qp-fp)),np.max(np.abs(qn-fn))))
bound=float(np.max(np.abs(np.asarray(model.WEIGHTS)/4096-weights))*105+abs(model.BIAS/(1<<22)-bias)+0.0001)
counts['maximum_absolute_score_error']=maximum_error
counts['derived_error_bound']=bound
manifest.update(counts)
targets=[candidate/'hog_model_manifest.json']
if load_baseline(root/'tools/hog_model.py').MODEL_ID==model.MODEL_ID:
    targets.append(root/'doc/hog_model_manifest.json')
for target in targets:
    target.write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(counts),flush=True)
assert counts['positive_quantization_disagreements']==0 and counts['positive_quantization_disagreements_at_zero']==0
assert max(counts['negative_quantization_disagreements'],counts['negative_quantization_disagreements_at_zero'])/len(qn)<=0.0001
assert maximum_error<=bound
print('PASS quantization: no positive decisions changed; background boundary differences <=0.01%; error within derived bound',flush=True)
