"""Publish the first six fixed Drill sets; never rewrite an existing course."""
import hashlib
import json
from pathlib import Path
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
C = ROOT/'backend/content'
R = ROOT/'frontend/IPadApp/IPadApp/Resources'
NAME = 'drill-stage-sets-v1.json'

def read(p): return json.loads(p.read_text(encoding='utf-8'))
def raw(value): return (json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode()
def digest(data): return hashlib.sha256(data).hexdigest()

def build():
    pools = read(C/'question-pools.json')['records']
    memory = read(C/'drills/memory-run-v2.json')
    sources = {s['id']:s for s in memory['sources']}
    def identity(s):
        if s.get('collection') == 'library':
            return str(uuid.uuid5(uuid.NAMESPACE_URL,'https://sori.local/practice-bank/trained-ear/'+s['id']))
        return s['id']
    def allowed(s):
        return s.get('collection') == 'classical' or pools.get(identity(s),{}).get('pool') == 'practice'
    def provenance(s):
        return dict(source_id=s['id'],question_id=identity(s),source_file=s['file'],source_sha256=s['sha256'],collection=s['collection'])
    sample = read(R/'small-demo-memory-run-v2.json')
    candidates = sorted((e for e in sample['excerpts'] if e['bars']==2 and allowed(sources[e['sourceId']])
                         and 3<=e['attacks']<=8),key=lambda e:(e['score'],e['id']))
    selected = []
    for e in candidates:
        if e['fingerprint'] not in {v['fingerprint'] for v in selected}: selected.append(e)
    assert len(selected)>=8
    stages = {}
    for number,group in [(2,selected[:4]),(6,selected[4:8])]:
        stages[number] = dict(number=number,game='memoryRun',questions=[
            dict(id=e['id'],catalog_id=e['id'],bpm=72 if number==2 else 80,first_measure=e['first'],bars=e['bars'],**provenance(sources[e['sourceId']])) for e in group])
    all_rhythms = read(C/'rhythm-puzzle-v3.json')['rounds']
    # Reuse rounds already present in the tiny demo. The first six stages must
    # not pull a large second engraving atlas into the installation package.
    rhythms = [r for level in ['beginner','intermediate','advanced'] for r in [x for x in all_rhythms if x['level']==level][:8]]
    candidates = sorted((r for r in rhythms if (r.get('collection')=='classical' or pools.get(r['question_id'],{}).get('pool')=='practice')
                         and r['level']!='advanced'),key=lambda r:(r['difficulty']['raw'],r['id']))
    used = set()
    for number in [3,5]:
        group = []; source_ids = set(); patterns = set()
        for r in candidates:
            if r['id'] in used or sum(x['question_id']==r['question_id'] for x in group)>=2 or r['rhythm_key'] in patterns: continue
            group.append(r); used.add(r['id']); source_ids.add(r['question_id']); patterns.add(r['rhythm_key'])
            if len(group)==5: break
        assert len(group)==5
        stages[number] = dict(number=number,game='rhythmPuzzle',questions=[dict(id=r['id'],catalog_id=r['id'],
            question_id=r['question_id'],question_version=r['question_version'],first_measure=r['first_measure'],bars=2,
            source_sha256=r['source_xml_sha256'],collection=r.get('collection','practice'),bpm=r['tempo_bpm']) for r in group])
    # Echo uses exact pitches from the existing practice/classical scores. No
    # transposition, mirrored response, alternative pitch mapping, or single-note answer.
    pairs = []
    for s in sorted(sources.values(),key=lambda s:s['id']):
        if not allowed(s): continue
        data = (C/'drills'/s['file']).read_bytes(); assert digest(data)==s['sha256']
        root = ET.fromstring(data)
        for measure in root.findall('part/measure')[:2]:
            notes=[]
            for i,n in enumerate(measure.findall('note'),1):
                p=n.find('pitch')
                if p is None or n.find("tie[@type='stop']") is not None: continue
                midi=(int(p.findtext('octave'))+1)*12+{'C':0,'D':2,'E':4,'F':5,'G':7,'A':9,'B':11}[p.findtext('step')]+int(p.findtext('alter','0'))
                notes.append((i,midi))
            for a,b in zip(notes,notes[1:]):
                if 60<=a[1]<=76 and 60<=b[1]<=76 and 1<=abs(a[1]-b[1])<=5:
                    pairs.append(dict(id=s['id']+':'+measure.attrib['number']+':'+str(a[0]),
                        first_measure=int(measure.attrib['number']),note_indices=[a[0],b[0]],notes=[a[1],b[1]],
                        bpm=80,**provenance(s)))
    chosen=set()
    for number in [1,4]:
        group=[]; seen=set()
        ordered=sorted(pairs,key=lambda p:(abs(p['notes'][1]-p['notes'][0]) if number==1 else abs(abs(p['notes'][1]-p['notes'][0])-3),p['id']))
        for p in ordered:
            if p['id'] in chosen or tuple(p['notes']) in seen: continue
            group.append(p); chosen.add(p['id']); seen.add(tuple(p['notes']))
            if len(group)==6: break
        assert len(group)==6
        stages[number]=dict(number=number,game='echoDragon',questions=group)
    course=dict(version='drill-stage-sets-1',stages=[stages[n] for n in sorted(stages)])
    target=C/'drills'/NAME; content=raw(course)
    if target.exists() and target.read_bytes()!=content: raise ValueError('Publish a new course version instead of overwriting v1')
    target.write_bytes(content); (R/NAME).write_bytes(content)
    return course

if __name__=='__main__':
    value=build()
    print('Fixed stage counts:',[(s['number'],len(s['questions'])) for s in value['stages']])
