"""Publish the v5 answer sheets as new immutable question versions.

Render the templates first (scripts/sheet-v5/build.sh). Every question whose current
version uses a v4 sheet gets version + 1 with the matching v5 sheet. Music, reference
images, IDs, older versions and attempt snapshots stay unchanged.
"""
import copy
import json
import shutil
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
# Same order as backend/solfege/catalogs.py; later files hold later versions.
CATALOGS=['catalog.json','classical-catalog.json','additional-practice-catalog.json','sheet-revisions.json',
          'brahms-catalog.json','classical-tempo-revisions.json','mahler-catalog.json','practice-bank-catalog.json']
OUTPUT='sheet-revisions-v5.json'


def write_json(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


def current_versions():
    latest={}
    for filename in CATALOGS:
        for item in json.loads((CONTENT/filename).read_text(encoding='utf-8')):
            qid=item['metadata']['id']
            if qid not in latest or item['metadata']['version']>latest[qid]['metadata']['version']:
                latest[qid]=item
    return latest


def main():
    revisions=[]; layouts={}
    for original in current_versions().values():
        q=original['metadata']; old_id=q['sheet_layout']['id']
        if not old_id.endswith('-v4'): continue
        new_id=old_id[:-len('-v4')]+'-v5'
        if new_id not in layouts:
            layouts[new_id]=json.loads((CONTENT/'sheets'/(new_id+'.layout.json')).read_text(encoding='utf-8'))
        item=copy.deepcopy(original); m=item['metadata']; old_version=m['version']; m['version']+=1
        m['sheet_layout']=copy.deepcopy(layouts[new_id])
        for asset in m['score_assets'].values():
            asset['url']=asset['url'].replace(f'/versions/{old_version}/',f'/versions/{m["version"]}/')
        # A sheet revision never publishes different music.
        assert item['main_path']==original['main_path'] and item['scale_path']==original['scale_path']
        revisions.append(item)
    revisions.sort(key=lambda x:(x['order'],x['metadata']['id']))
    assert len(revisions)==len({x['metadata']['id'] for x in revisions})
    write_json(CONTENT/OUTPUT,revisions)
    write_json(RESOURCES/OUTPUT,[x['metadata'] for x in revisions])
    for layout_id in layouts:
        shutil.copyfile(CONTENT/'sheets'/(layout_id+'.png'),RESOURCES/(layout_id+'.pngdata'))
    print(f'Published {len(revisions)} v5 sheet versions on {len(layouts)} templates; older versions unchanged.')


if __name__=='__main__':main()
