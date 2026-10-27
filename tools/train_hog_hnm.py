"""Expanded integer-HOG training with grouped splits and training-only hard negatives."""
from __future__ import annotations
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import struct
import time
import zlib
import numpy as np
from PIL import Image
from sklearn.svm import LinearSVC
from sklearn.metrics import average_precision_score
from threadpoolctl import threadpool_limits
from hog_training import descriptor,feature_map,all_windows,gray_array,select_spaced,integer_scores
from hog_reference import extract_window,nms
from format_hdl_layout import format_source
from hog_client import prepare_hog

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'tools/datasets/inria_hog'
SEED=20261022


def log(*args): print(*args,flush=True)


def image_key(item):
    return item['category']+'/'+re.sub('[a-z]+$','',Path(item['path']).stem)


def split_data(source,baseline):
    """Exact/mirrored pixel duplicates and named crop families stay in one partition."""
    parent={item['path']:item['path'] for item in source['files']}
    def find(key):
        while parent[key]!=key:
            parent[key]=parent[parent[key]]
            key=parent[key]
        return key
    def union(a,b):
        a,b=find(a),find(b)
        if a!=b: parent[max(a,b)]=min(a,b)
    seen={}
    for number,item in enumerate(source['files']):
        gray=gray_array(DATA/item['path'])
        if gray.shape[0]<128 or gray.shape[1]<64: raise ValueError(f'Image too small: {item["path"]}')
        token=min(hashlib.sha256(gray.tobytes()).hexdigest(),hashlib.sha256(gray[:,::-1].tobytes()).hexdigest())
        for key in ('name:'+image_key(item),'pixels:'+item['category']+str(gray.shape)+token):
            if key in seen: union(item['path'],seen[key])
            else: seen[key]=item['path']
        if (number+1)%400==0: log('Split audit',number+1)
    old_paths={i['path'] for i in baseline['files']}
    reserved={find(path) for path in old_paths}
    groups={}
    for item in source['files']: groups.setdefault(find(item['path']),[]).append(item)
    splits={'train':[],'validation':[],'test':[]}
    membership={}
    for key,items in sorted(groups.items()):
        bucket=int(hashlib.sha256((str(SEED)+key).encode()).hexdigest()[:8],16)/2**32
        split='train' if key in reserved or bucket>=0.30 else ('validation' if bucket<0.15 else 'test')
        splits[split].extend(items)
        membership[key]=split
    for split in ('validation','test'):
        assert not any(i['path'] in old_paths for i in splits[split])
    return splits,{'groups':len(groups),'baseline_groups_forced_train':len(reserved),
                   'group_membership':membership,'rule':'named crop family + exact/mirrored pixel union; all 512 prior development images forced to training; new groups 70/15/15 by fixed hash',
                   'limitation':'Original source-scene identifiers are unavailable in this mirror; grouping does not certify original-scene disjointness.'}


def get_windows(item,cache):
    key=item['sha256']+'_320x240'
    destination=cache/f'{key}.npz'
    if destination.exists():
        with np.load(destination) as data: return all_windows(data['blocks']),int(data['columns'])
    # Match the deployed input path, including resize and padding, for training and evaluation backgrounds.
    with Image.open(DATA/item['path']) as image:
        payload,_=prepare_hog(image)
    gray=np.frombuffer(payload,dtype=np.uint8).reshape(240,320)
    blocks=feature_map(gray)
    windows=all_windows(blocks)
    columns=gray.shape[1]//8-7
    np.savez_compressed(destination,blocks=blocks,columns=columns)
    return windows,columns


def make_base(files,cache,training,rng):
    vectors=[]
    labels=[]
    used={}
    positives=[]
    for number,item in enumerate(files):
        if item['category']=='pedestrians':
            gray=gray_array(DATA/item['path'])
            x,y=(gray.shape[1]-64)//2,(gray.shape[0]-128)//2
            locations=[(x,y)]
            if training:
                for dx,dy in [(-4,4),(4,-4)]:
                    locations.append((max(0,min(gray.shape[1]-64,x+dx)),max(0,min(gray.shape[0]-128,y+dy))))
            row=np.array([descriptor(gray,px,py) for px,py in locations],dtype=np.uint16)
            if not positives:
                assert row[0].tolist()==extract_window(gray.tobytes(),gray.shape[1],gray.shape[0],x,y)
            positives.append(row[0])
            vectors.append(row)
            labels.extend([1]*len(row))
        else:
            windows,_=get_windows(item,cache)
            selected=sorted(rng.choice(len(windows),size=min(12,len(windows)),replace=False).tolist())
            used[item['path']]=set(selected)
            vectors.append(windows[selected])
            labels.extend([0]*len(selected))
        if (number+1)%250==0: log('Base features',number+1,'/',len(files),'training' if training else 'evaluation')
    return np.concatenate(vectors),np.array(labels,dtype=np.int8),np.array(positives,dtype=np.uint16),used


def score_rows(rows,weight,bias):
    return rows.astype(np.float32)@weight.astype(np.float32)/1024+float(bias)


def evaluation(files,pos_rows,weight,bias,cache,threshold=None,quantized=None):
    def calculate(rows):
        return score_rows(rows,weight,bias) if quantized is None else integer_scores(rows,*quantized)/(1<<22)
    positive_scores=calculate(pos_rows)
    # Calibrate on validation positives to 90% window recall, without inspecting test data.
    if threshold is None: threshold=round(float(np.quantile(positive_scores,0.10)),4)
    background_scores=[]
    background_counts=[]
    background_counts_zero=[]
    for item in files:
        if item['category']!='no_pedestrians': continue
        windows,columns=get_windows(item,cache)
        scores=calculate(windows)
        background_scores.append(scores)
        if columns!=33:
            raise ValueError('Expected 320-wide background frames for the fixed hardware validation')
        background_counts.append(len(nms(scores,threshold)))
        background_counts_zero.append(len(nms(scores,0)))
    negative_scores=np.concatenate(background_scores)
    labels=np.r_[np.ones(len(positive_scores)),np.zeros(len(negative_scores))]
    combined=np.r_[positive_scores,negative_scores]
    metrics={'positive_windows':len(positive_scores),'negative_windows':len(negative_scores),
             'background_images':len(background_scores),'threshold':float(threshold),
             'positive_recall':float(np.mean(positive_scores>threshold)),
             'background_window_false_positive_rate':float(np.mean(negative_scores>threshold)),
             'background_false_boxes_per_image':float(np.mean(background_counts)),
             'background_total_false_boxes':int(sum(background_counts)),
             'positive_recall_at_zero':float(np.mean(positive_scores>0)),
             'background_false_boxes_per_image_at_zero':float(np.mean(background_counts_zero)),
             'window_average_precision':float(average_precision_score(labels,combined))}
    return metrics,positive_scores,negative_scores


def load_baseline(path):
    spec=importlib.util.spec_from_file_location('old_hog_model',path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def export_model(out,model,threshold,manifest):
    weights=np.rint(model.coef_.ravel()*4096).astype(np.int64)
    bias=int(round(float(model.intercept_[0])*(1<<22)))
    if np.max(np.abs(weights))>=32768 or not -(1<<31)<=bias<(1<<31): raise ValueError('SVM fixed-point range exceeded')
    # Keep the established GUI operating point at zero; expose validation calibration separately.
    raw_threshold=0
    packed=struct.pack('<i',bias)+struct.pack('<3780h',*weights)
    model_id=zlib.crc32(packed)
    text=('"""Expanded data and training-only hard-negative mining; integer-HOG feature v1."""\n'
          f'MODEL_ID = 0x{model_id:08X}\nBIAS = {bias}\nSCORE_SHIFT = 22\nTHRESHOLD = {raw_threshold}\nDEFAULT_THRESHOLD = 0.0\nVALIDATION_RECALL_THRESHOLD = {threshold!r}\nWEIGHTS = (\n')
    text+=''.join('    '+', '.join(str(int(v)) for v in weights[i:i+18])+',\n' for i in range(0,len(weights),18))+')\n'
    (out/'hog_model.py').write_text(text,encoding='utf-8')
    (out/'hog_svm_weights.mem').write_text(''.join(f'{int(v)&65535:04x}\n' for v in weights),encoding='ascii')
    rtl=(ROOT/'rtl/hog_svm_model.v').read_text(encoding='utf-8')
    rtl=re.sub(r"assign bias = 32'h[0-9a-fA-F]+;",f"assign bias = 32'h{bias&0xffffffff:08x};",rtl)
    rtl=re.sub(r"assign model_id = 32'h[0-9a-fA-F]+;",f"assign model_id = 32'h{model_id:08x};",rtl)
    (out/'hog_svm_model.v').write_text(format_source(rtl),encoding='utf-8')
    manifest.update(model_id=f'{model_id:08X}',weights_sha256=hashlib.sha256(packed).hexdigest(),threshold=raw_threshold,
                    default_threshold=0.0,validation_recall_threshold=threshold,weight_fraction_bits=12,score_fraction_bits=22,window=[64,128],
                    descriptor='hard 9-bin unsigned gradient / 8x8 cells / L1 Q10 2x2 blocks')
    return weights,bias


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rounds',type=int,default=3)
    parser.add_argument('--output',type=Path,default=ROOT/'tools/model_candidates/hog_hnm_v2')
    args=parser.parse_args()
    out=args.output.resolve()
    out.mkdir(parents=True,exist_ok=True)
    cache=ROOT/'tools/training_cache/hog_integer_v1'
    cache.mkdir(parents=True,exist_ok=True)
    source=json.loads((DATA/'source_expanded.json').read_text())
    baseline_source=json.loads((DATA/'source.json').read_text())
    old=load_baseline(ROOT/'tools/model_versions/hog_D2A8B58B/hog_model.py')
    splits,audit=split_data(source,baseline_source)
    (out/'split_audit.json').write_text(json.dumps(audit,indent=2),encoding='utf-8')
    log('SPLITS',{s:{c:sum(i['category']==c for i in files) for c in ('pedestrians','no_pedestrians')} for s,files in splits.items()})
    rng=np.random.default_rng(SEED)
    x,y,_,used=make_base(splits['train'],cache,True,rng)
    _,_,vp,_=make_base([i for i in splits['validation'] if i['category']=='pedestrians'],cache,False,rng)
    log('Initial train windows',len(x),'positive',int(y.sum()))
    history=[]
    candidates=[]
    with threadpool_limits(limits=4):
        best=None
        for c in (0.01,0.1,1.0):
            model=LinearSVC(C=c,class_weight='balanced',dual='auto',max_iter=20000,random_state=SEED)
            model.fit(x.astype(np.float32)/1024,y)
            metrics,_,_=evaluation(splits['validation'],vp,model.coef_.ravel(),model.intercept_[0],cache)
            selection=(-metrics['background_false_boxes_per_image'],metrics['window_average_precision'])
            record={'round':0,'C':c,'train_windows':len(x),'validation':metrics,'iterations':int(model.n_iter_)}
            history.append(record)
            log('VALIDATION',json.dumps(record))
            if best is None or selection>best[0]: best=(selection,model,metrics)
        model=best[1]
        candidates.append((best[0],model,best[2],0))
        for round_number in range(1,args.rounds+1):
            additions=[]
            mined=[]
            for number,item in enumerate(i for i in splits['train'] if i['category']=='no_pedestrians'):
                windows,columns=get_windows(item,cache)
                scores=score_rows(windows,model.coef_.ravel(),model.intercept_[0])
                selected=select_spaced(scores,columns,used[item['path']],limit=16,minimum=-0.2)
                if selected:
                    additions.append(windows[selected])
                    used[item['path']].update(selected)
                    mined.extend({'path':item['path'],'window_index':i,'score_before':float(scores[i])} for i in selected)
                if (number+1)%150==0: log('MINING round',round_number,'backgrounds',number+1,'new windows',len(mined))
            (out/f'hard_negatives_round_{round_number}.json').write_text(json.dumps(mined,indent=2),encoding='utf-8')
            if not additions:
                log('No new hard negatives; converged')
                break
            extra=np.concatenate(additions)
            x=np.concatenate([x,extra])
            y=np.r_[y,np.zeros(len(extra),dtype=np.int8)]
            model=LinearSVC(C=model.C,class_weight='balanced',dual='auto',max_iter=20000,random_state=SEED)
            model.fit(x.astype(np.float32)/1024,y)
            metrics,_,_=evaluation(splits['validation'],vp,model.coef_.ravel(),model.intercept_[0],cache)
            selection=(-metrics['background_false_boxes_per_image'],metrics['window_average_precision'])
            candidates.append((selection,model,metrics,round_number))
            record={'round':round_number,'C':model.C,'new_hard_negatives':len(extra),'train_windows':len(x),'validation':metrics,'iterations':int(model.n_iter_)}
            history.append(record)
            log('VALIDATION',json.dumps(record))
        selected=max(candidates,key=lambda c:c[0])
        model,vm,selected_round=selected[1:]
        threshold=vm['threshold']
        log('SELECTED round',selected_round,'C',model.C,'threshold',threshold)
        # Freeze model and threshold before accessing the independent test split.
        manifest={'seed':SEED,'source':source['source'],'revision':source['revision'],'source_image_count':len(source['files']),
                  'train_images':[i['path'] for i in splits['train']],
                  'validation_images':[i['path'] for i in splits['validation']],
                  'test_images':[i['path'] for i in splits['test']],
                  'split_rule':audit['rule'],'split_limitation':audit['limitation'],'history':history,'selected_round':selected_round,
                  'selected_C':model.C,'validation_metrics':vm,'mining_rounds_executed':len(candidates)-1,
                  'selection_rule':'minimum validation background false boxes/image at threshold calibrated to 90% positive-window recall; AP tie-break',
                  'test_usage':'Only evaluated after training/checkpoint and threshold were frozen; never mined or used for selection.'}
        weights,bias=export_model(out,model,threshold,manifest)
        _,_,tp,_=make_base([i for i in splits['test'] if i['category']=='pedestrians'],cache,False,rng)
        old_weight=np.array(old.WEIGHTS,dtype=np.float64)/4096
        old_bias=old.BIAS/(1<<22)
        old_validation,_,_=evaluation(splits['validation'],vp,old_weight,old_bias,cache,quantized=(old.WEIGHTS,old.BIAS))
        old_test,_,_=evaluation(splits['test'],tp,old_weight,old_bias,cache,old_validation['threshold'],quantized=(old.WEIGHTS,old.BIAS))
        new_test,_,_=evaluation(splits['test'],tp,None,None,cache,threshold,quantized=(weights,bias))
        quantized_validation,qv,qn=evaluation(splits['validation'],vp,None,None,cache,threshold,quantized=(weights,bias))
        floating_validation,fp,fn=evaluation(splits['validation'],vp,model.coef_.ravel(),model.intercept_[0],cache,threshold)
        manifest.update(baseline_model_id=f'{old.MODEL_ID:08X}',baseline_validation_metrics=old_validation,
                        independent_test={'baseline':old_test,'new_quantized':new_test},
                        quantized_validation_metrics=quantized_validation,
                        positive_quantization_disagreements=int(np.count_nonzero((qv>threshold)!=(fp>threshold))),
                        negative_quantization_disagreements=int(np.count_nonzero((qn>threshold)!=(fn>threshold))),
                        positive_quantization_disagreements_at_zero=int(np.count_nonzero((qv>0)!=(fp>0))),
                        negative_quantization_disagreements_at_zero=int(np.count_nonzero((qn>0)!=(fn>0))))
        # Test samples provide new algorithm simulation vectors; user photographs remain outside training.
        positive=next(i for i in splits['test'] if i['category']=='pedestrians')
        negative=next(i for i in splits['test'] if i['category']=='no_pedestrians')
        scene=Image.open(DATA/negative['path']).convert('L').resize((320,240))
        crop=Image.open(DATA/positive['path']).convert('L')
        scene.paste(crop,(112,40))
        scene.save(out/'hog_validation_scene.png')
        (out/'hog_frame.mem').write_text(''.join(f'{b:02x}\n' for b in scene.tobytes()),encoding='ascii')
        manifest['simulation_scene_sources']=[positive['path'],negative['path']]
        (out/'hog_model_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
        np.savez_compressed(out/'floating_model.npz',weights=model.coef_.ravel(),bias=model.intercept_,threshold=threshold)
        log('INDEPENDENT TEST',json.dumps(manifest['independent_test']))
        log('PASS training export',manifest['model_id'],out)


if __name__=='__main__': main()
