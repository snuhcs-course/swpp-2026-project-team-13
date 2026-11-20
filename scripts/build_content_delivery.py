"""Migrate existing drill fixtures to server assets and build the tiny offline demo.

Full frontend resources remain test fixtures. Only the generated demo index and
the runtime allowlist are admitted to device installation builds.
"""
import copy
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RES=ROOT/'frontend/IPadApp/IPadApp/Resources'
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def write(p,value):p.write_bytes((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
def sha(data):return hashlib.sha256(data).hexdigest()

def publish_drills():
    target=CONTENT/'drills';target.mkdir(exist_ok=True)
    names=['memory-run-v2.json','memory-groove-v1.json','rhythm-engraving-v3.json']
    if (RES/'drill-stage-sets-v1.json').exists(): names.append('drill-stage-sets-v1.json')
    memory=read(RES/'memory-run-v2.json')
    names += sorted({s['file'] for s in memory['sources']})
    for name in names:
        if Path(name).name!=name:raise ValueError('Content filename must be a basename')
        source=RES/name;destination=target/name
        if destination.exists() and destination.read_bytes()!=source.read_bytes():
            raise ValueError('Published drill content is immutable: '+name)
        shutil.copyfile(source,destination)
    paths=[CONTENT/f'rhythm-puzzle-v{i}.json' for i in (1,2,3)]+[target/name for name in names]
    assets={};files={}
    for path in paths:
        data=path.read_bytes();digest=sha(data)
        mime='application/json' if path.suffix=='.json' else 'application/xml'
        assets[path.name]={'sha256':digest,'size_bytes':len(data),'content_type':mime}
        files[digest]={'path':path.relative_to(CONTENT).as_posix(),**assets[path.name]}
    write(CONTENT/'client-content-manifest.json',{'version':1,'assets':assets,'files':files})
    print(f'Published {len(assets)} immutable server content assets.')

def small_demo():
    latest={}
    for name in ['catalog.json','classical-catalog.json','additional-practice-catalog.json','sheet-revisions.json','brahms-catalog.json','classical-tempo-revisions.json','mahler-catalog.json','practice-bank-catalog.json','sheet-revisions-v5.json','sheet-revisions-v6.json']:
        for item in read(CONTENT/name):
            q=item['metadata']
            if q['id'] not in latest or latest[q['id']]['metadata']['version']<q['version']:latest[q['id']]=item
    difficulty=read(RES/'practice-difficulty.json');pool=read(RES/'question-pools.json')
    base=read(CONTENT/'catalog.json')[:3];ids=[q['metadata']['id'] for q in base]
    candidates=[i for i in latest.values() if pool['records'].get(i['metadata']['id'],{}).get('pool')=='exam' and i['metadata'].get('difficulty') is not None]
    # Include an easier and a matched choice around the initial rating of 7.
    # A single Level-1 sample can leave the demo's Easy card empty.
    for target in [5.9,7.0,80.0]:
        q=min((i for i in candidates if i['metadata']['id'] not in ids),key=lambda i:(abs(difficulty['records'][i['metadata']['id']]['score']-target),i['metadata']['id']))
        ids.append(q['metadata']['id'])
    keep=set();index={};questions=[]
    for number,qid in enumerate(ids):
        item=latest[qid];q=copy.deepcopy(item['metadata']);questions.append(q)
        keep.update([q['sheet_layout']['id']+'.pngdata',q['reference_display']['resource']+'.pngdata'])
        for kind in ['main','scale']:
            if number<3:name=f'excerpt-{number+1}-v2-{kind}.mxl'
            else:name=f'practice-{qid}-{kind}.mxl'
            if sha((RES/name).read_bytes())!=q['score_assets'][kind]['sha256']:raise ValueError('Demo score mismatch: '+name)
            keep.add(name)
    diff=copy.deepcopy(difficulty);diff['records']={k:v for k,v in diff['records'].items() if k in ids};diff.pop('calibration',None)
    pools={'version':pool['version'],'records':{qid:{'pool':'practice' if i<3 else 'exam','family':qid} for i,qid in enumerate(ids)}}
    previews=read(RES/'practice-layout-v2.json');previews['scores']={k:v for k,v in previews['scores'].items() if k in {q['score_assets']['main']['sha256'] for q in questions}};previews.pop('audit',None)
    payloads={'catalog':questions,'difficulty':diff,'pools':pools,'engraving':previews}
    # Keep enough distinct simple phrases for all four rounds, including Groove.
    memory=read(RES/'memory-run-v2.json');groove=read(RES/'memory-groove-v1.json');excluded=set(groove['excludedExcerptIds'])
    chosen=[];sources=set();fingerprints=set()
    for bars,strict,count in [(2,True,8),(2,False,4),(4,False,8)]:
        candidates=sorted(memory['excerpts'],key=lambda e:(e['score'],e['id']))
        selected=0
        for e in candidates:
            if e['bars']!=bars or e['sourceId'] in sources or e['fingerprint'] in fingerprints or e['id'] in excluded:continue
            if strict and not (e['beginnerEligible'] and e['attacks']<=5 and e['pitchRange']<=5 and e['largestInterval']<=2):continue
            chosen.append(e);sources.add(e['sourceId']);fingerprints.add(e['fingerprint']);selected+=1
            if selected==count:break
        if selected!=count:raise ValueError('Not enough distinct demo memory phrases')
    memory={**memory,'sources':[s for s in memory['sources'] if s['id'] in sources],'excerpts':chosen}
    payloads['memory-run-v2']=memory
    for s in memory['sources']:keep.add(s['file'])
    raw=(json.dumps(memory,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
    payloads['memory-groove-v1']={'version':'memory-groove-v1','catalogSha256':sha(raw),'excludedExcerptIds':[]}
    rhythm=read(RES/'rhythm-puzzle-v3.json');rounds=[]
    for level in ['beginner','intermediate','advanced']:rounds += [r for r in rhythm['rounds'] if r['level']==level][:8]
    if (RES/'drill-stage-sets-v1.json').exists():
        course=read(RES/'drill-stage-sets-v1.json')
        required={q['catalog_id'] for s in course['stages'] if s['game']=='rhythmPuzzle' for q in s['questions']}
        rounds += [r for r in rhythm['rounds'] if r['id'] in required and r['id'] not in {v['id'] for v in rounds}]
        payloads['drill-stage-sets-v1']=course
    tileids={t for r in rounds for t in r['choices']}|{p['tile_id'] for r in rounds for p in r['solution']}
    rhythm={**rhythm,'rounds':rounds,'tiles':[t for t in rhythm['tiles'] if t['id'] in tileids],'exceptions':[],'source_count':len({r['question_id'] for r in rounds})}
    payloads['rhythm-puzzle-v3']=rhythm
    raw=(json.dumps(rhythm,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
    ink=read(RES/'rhythm-engraving-v3.json');ink['catalog_sha256']=sha(raw);ink['tiles']={k:v for k,v in ink['tiles'].items() if k in tileids};payloads['rhythm-engraving-v3']=ink
    for name,value in payloads.items():
        filename='small-demo-'+name+'.json';write(RES/filename,value);keep.add(filename);index[name]=filename
    write(RES/'small-demo-index.json',{'version':1,'files':index,'required_files':sorted(keep),'question_count':len(questions)})
    print(f'Built {len(questions)} sample questions, {len(chosen)} Memory phrases and {len(rounds)} Rhythm rounds.')

if __name__=='__main__':publish_drills();small_demo()
