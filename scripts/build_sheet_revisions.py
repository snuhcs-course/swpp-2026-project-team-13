"""Publish compact handwriting sheets as new immutable question versions.

Run build_classical_sheets.ps1 -Compact first. Music, reference images, IDs,
old sheets and previous attempt snapshots stay unchanged.
"""
import copy
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'


def write_json(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


def main():
    revisions=[]
    for filename in ['catalog.json','classical-catalog.json','additional-practice-catalog.json']:
        for original in json.loads((CONTENT/filename).read_text(encoding='utf-8')):
            item=copy.deepcopy(original); q=item['metadata']; old_version=q['version']; q['version']+=1
            meter=q['time_signature']; fifths=q['key_signature']['fifths']
            layout=q['sheet_layout']; layout_id=f'staff-8bars-{meter["numerator"]}-{meter["denominator"]}-key{fifths}-v4'
            png=(CONTENT/'sheets'/(layout_id+'.png')).read_bytes()
            layout.update(id=layout_id,template_png_url=f'https://api.sori.example/assets/sheets/{layout_id}.png',template_sha256=hashlib.sha256(png).hexdigest(),display_height=620)
            layout['systems'][1]['staff_line_y']=[386,398,410,422,434]
            for asset in q['score_assets'].values():
                asset['url']=asset['url'].replace(f'/versions/{old_version}/',f'/versions/{q["version"]}/')
            path=CONTENT/'sheets'/(layout_id+'.layout.json')
            if path.exists():assert json.loads(path.read_text(encoding='utf-8'))==layout
            else:write_json(path,layout)
            (RESOURCES/(layout_id+'.pngdata')).write_bytes(png)
            # Existing main_path/scale_path and their hashes are deliberately
            # reused. A sheet revision does not publish different music.
            assert item['main_path']==original['main_path'] and item['scale_path']==original['scale_path']
            revisions.append(item)
    assert len(revisions)==len({x['metadata']['id'] for x in revisions})==124
    write_json(CONTENT/'sheet-revisions.json',revisions)
    write_json(RESOURCES/'sheet-revisions.json',[x['metadata'] for x in revisions])
    print('Published 124 new sheet versions: staff distance 335 -> 222, final barline, visible height 620; old assets unchanged.')


if __name__=='__main__':main()
