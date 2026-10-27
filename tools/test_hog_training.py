"""Cross-check the training implementation with the scalar, hardware-facing reference."""
import unittest
import tempfile
from pathlib import Path
import numpy as np
from PIL import Image
from hog_training import descriptor,feature_map,all_windows,select_spaced,integer_scores
from hog_reference import extract_window,cell_histograms,block_features,svm_scores


class TrainingTests(unittest.TestCase):
    def test_vectorized_maps_and_every_window(self):
        rng=np.random.default_rng(6201)
        gray=rng.integers(0,256,(152,88),dtype=np.uint8)
        blocks=feature_map(gray)
        expected=block_features(cell_histograms(gray.tobytes(),88,152),11,19)
        self.assertEqual(blocks.ravel().tolist(),expected)
        windows=all_windows(blocks)
        self.assertEqual(windows.shape,(16,3780))
        for y in range(4):
            for x in range(4):
                self.assertEqual(windows[y*4+x].tolist(),extract_window(gray.tobytes(),88,152,x*8,y*8))
        weights=rng.integers(-32000,32000,3780,dtype=np.int16)
        self.assertEqual(integer_scores(windows,weights,-739182).tolist(),svm_scores(expected,weights.tolist(),-739182,11,19))

    def test_halo_unaligned_and_image_edges(self):
        rng=np.random.default_rng(73)
        gray=rng.integers(0,256,(160,96),dtype=np.uint8)
        for x,y in [(0,0),(16,16),(12,20),(32,32)]:
            self.assertEqual(descriptor(gray,x,y).tolist(),extract_window(gray.tobytes(),96,160,x,y))

    def test_miner_threshold_exclusions_and_spacing(self):
        scores=np.array([1,4,3,-1,-2,2],dtype=float)
        selected=select_spaced(scores,6,excluded=[1],limit=2,minimum=0)
        self.assertTrue(1 not in selected and all(scores[i]>0 for i in selected))
        self.assertEqual(select_spaced(np.full(10,-2.0),10),[])

    def test_group_split_preserves_prior_and_mirrored_data(self):
        import train_hog_hnm as trainer
        rng=np.random.default_rng(204)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'pedestrians').mkdir()
            gray=rng.integers(0,256,(160,96),dtype=np.uint8)
            files=[]
            for name,array in [('person_1a.png',gray),('renamed_9a.png',gray[:,::-1]),
                               ('person_1b.png',rng.integers(0,256,(160,96),dtype=np.uint8))]:
                Image.fromarray(array).save(root/'pedestrians'/name)
                files.append({'path':'pedestrians/'+name,'category':'pedestrians'})
            for i in range(30):
                name=f'new_{i}a.png'
                Image.fromarray(rng.integers(0,256,(160,96),dtype=np.uint8)).save(root/'pedestrians'/name)
                files.append({'path':'pedestrians/'+name,'category':'pedestrians'})
            original=trainer.DATA
            try:
                trainer.DATA=root
                splits,audit=trainer.split_data({'files':files},{'files':[files[0]]})
            finally:
                trainer.DATA=original
            training={i['path'] for i in splits['train']}
            self.assertTrue({i['path'] for i in files[:3]}<=training)
            partitions=[{i['path'] for i in splits[name]} for name in ('train','validation','test')]
            self.assertTrue(all(partitions))
            self.assertFalse(partitions[0]&partitions[1] or partitions[0]&partitions[2] or partitions[1]&partitions[2])


if __name__=='__main__': unittest.main()
