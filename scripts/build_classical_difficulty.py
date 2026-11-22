"""Publish the shared eight-bar scorer at each classical exercise's PLAYBACK tempo.

This overlay never edits a shipped score, its metadata or the Practice/Exam split.
The denominator is the meter's standard Practice tempo, not the score's own tempo:
otherwise a fast score divided by itself would silently erase the speed effect.
"""
from pathlib import Path
import sys
import json

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content';RES=ROOT/'frontend/IPadApp/IPadApp/Resources'
sys.path.insert(0,str(ROOT/'backend'))
from solfege.rhythm import current_sources
from solfege.features.musicxml import read_xml
from solfege.difficulty import analyze,VERSION,CUTOFFS
from solfege.playback import question_tempo,resolve_tempo,quarter_bpm

def build():
    records={}
    for row in current_sources(CONTENT,include_classical=True):
        q=row['metadata']
        if q.get('collection')!='classical':continue
        raw=read_xml(CONTENT/row['main_path'])
        actual=quarter_bpm(question_tempo(q));reference=quarter_bpm(resolve_tempo(q['time_signature']))
        a=analyze(raw,quarter_bpm=actual,reference_quarter_bpm=reference)
        records[q['id']]=dict(main_sha256=q['score_assets']['main']['sha256'],
            **{k:a[k] for k in ['content_score','key_correction','score_floor','reference_quarter_bpm','quarter_bpm','score','level']})
    return dict(asset_version='classical-difficulty-1',version=VERSION,cutoffs=list(CUTOFFS),records=records)

def main():
    value=build();data=(json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
    for path in [CONTENT/'classical-difficulty-v1.json',RES/'classical-difficulty-v1.json']:
        if path.exists() and path.read_bytes()!=data:raise ValueError('Publish a new classical difficulty revision')
        path.write_bytes(data)
    print('Published classical tempo-aware difficulty:',len(value['records']))

if __name__=='__main__':main()
