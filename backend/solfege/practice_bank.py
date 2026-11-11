"""Score metadata overlays preserve immutable score assets and past attempts."""
import copy
import json
from functools import lru_cache
from pathlib import Path
from .difficulty import level_for_score, CUTOFFS, VERSION

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

def annotate(metadata):
    value=manifest()
    if value is None or metadata.get('collection')=='classical':return metadata
    entry=value['records'].get(metadata['id'])
    if not entry or entry['main_sha256']!=metadata['score_assets']['main']['sha256']:return metadata
    result=copy.deepcopy(metadata)
    from .playback import quarter_bpm
    speed=quarter_bpm(result['tempo'])/entry['reference_quarter_bpm']
    difficulty=(entry['content_score']+entry['key_correction'])*speed
    result.update(practice_level=level_for_score(difficulty),difficulty_score=difficulty,difficulty_version=value['version'])
    return result

def timed_practice_question(metadata, selected_bpm=None):
    from .playback import timed_question
    return annotate(timed_question(metadata,selected_bpm))
