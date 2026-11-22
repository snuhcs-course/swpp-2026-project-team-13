"""Score metadata overlays preserve immutable score assets and past attempts."""
import copy
import json
from functools import lru_cache
from pathlib import Path
from .difficulty import level_for_score, task_score, CUTOFFS, VERSION

PATH=Path(__file__).resolve().parents[1]/'content/practice-difficulty.json'

@lru_cache(maxsize=1)
def manifest():
    if not PATH.exists():return None
    value=json.loads(PATH.read_text(encoding='utf8'))
    if value['version']!=VERSION or value['cutoffs']!=list(CUTOFFS):
        raise ValueError('Rebuild practice difficulty metadata for the current scorer and cutoffs')
    return value

def visible_ids():
    value=manifest()
    return list(value['records']) if value else None

@lru_cache(maxsize=1)
def classical_manifest():
    path=PATH.with_name('classical-difficulty-v1.json')
    if not path.exists():return None
    value=json.loads(path.read_text(encoding='utf8'))
    if value['version']!=VERSION or value['cutoffs']!=list(CUTOFFS):raise ValueError('Classical difficulty formula mismatch')
    return value

def annotate(metadata):
    classical=metadata.get('collection')=='classical'
    value=classical_manifest() if classical else manifest()
    if value is None:return metadata
    entry=value['records'].get(metadata['id'])
    if not entry or entry['main_sha256']!=metadata['score_assets']['main']['sha256']:return metadata
    result=copy.deepcopy(metadata)
    from .playback import quarter_bpm
    speed=quarter_bpm(result['tempo'])/entry['reference_quarter_bpm']
    difficulty=task_score(entry['content_score'],entry['key_correction'],speed,entry['score_floor'])
    result.update(difficulty_score=difficulty,difficulty_version=value['version'])
    if not classical:result['practice_level']=level_for_score(difficulty)
    return result

def timed_practice_question(metadata, selected_bpm=None):
    from .playback import timed_question
    return annotate(timed_question(metadata,selected_bpm))
