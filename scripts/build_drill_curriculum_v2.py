"""Publish tempo-aware Memory/Rhythm revisions; never rewrite existing versions.

Echo Dragon's procedural course and character are intentionally outside this file.
"""
from collections import Counter
from copy import deepcopy
from fractions import Fraction as F
import bisect
import hashlib
import json
import math
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
C=ROOT/'backend/content'; R=ROOT/'frontend/IPadApp/IPadApp/Resources'
sys.path.insert(0,str(ROOT/'backend'))
from solfege.rhythm import current_sources
from solfege.features.musicxml import read_xml,parse_xml
from build_drill_score_drafts import identity,choose_spread

VERSION='drill-stage-sets-2'
MEMORY='memory-run-v3'; RHYTHM='rhythm-puzzle-v4'
PATTERN=['echoDragon','memoryRun','rhythmPuzzle','echoDragon','rhythmPuzzle','memoryRun','memoryRun','echoDragon','rhythmPuzzle']
CAPS=[0,0,1,1,2,2,3,3,7,7]

def read(p): return json.loads(p.read_text(encoding='utf-8'))
def raw(v): return (json.dumps(v,ensure_ascii=False,separators=(',',':'))+'\n').encode()
def sha(data): return hashlib.sha256(data).hexdigest()
def freeze(path,data):
    if path.exists() and path.read_bytes()!=data: raise ValueError('Publish a new version: '+str(path))
    path.write_bytes(data)

def classical_tempos():
    result={}
    factors={'quarter':1,'half':2,'dotted_quarter':1.5,'dotted_half':3}
    for row in current_sources(C,include_classical=True):
        m=row['metadata']
        if m.get('collection')!='classical': continue
        if m.get('tempo'):
            t=m['tempo']; bpm=t['bpm']*factors[t['beat_unit']]
            source='question_metadata'
        else:
            # These eleven imported scores contain sound tempo=96. Do not infer
            # an artistic/original tempo or replace it with a meter/game default.
            xml=parse_xml(read_xml(C/row['main_path']))
            marks=[float(s.get('tempo')) for s in xml.findall('.//sound') if s.get('tempo')]
            if not marks or len(set(marks))!=1: raise ValueError('Classical tempo needs review: '+m['id'])
            bpm=marks[0]; t=dict(beat_unit='quarter',bpm=bpm); source='published_score_xml'
        if not 40<=bpm<=240: raise ValueError('Unsupported quarter tempo: '+m['id'])
        result[m['id']]=dict(quarterBpm=bpm,tempoBeatUnit=t['beat_unit'],tempoDisplayBpm=t['bpm'],tempoSource=source)
    return result

def performance(base,bpm,attacks,quarters,shortest,kind):
    seconds=float(quarters)*60/bpm
    rate=attacks/seconds
    peak=bpm/60/float(shortest)
    # Relative music structure still dominates; faster real-time delivery adds
    # pressure even when exactly the same notated rhythm is used.
    scale=math.sqrt(bpm/80)
    a,b=(.10,.06) if kind=='memory' else (.25,.15)
    value=base*scale+a*math.log2(1+rate)+b*math.log2(1+peak)
    return dict(raw=round(value,8),baseRaw=base,quarterBpm=bpm,seconds=round(seconds,6),
                notesPerSecond=round(rate,6),peakNotesPerSecond=round(peak,6),tempoFactor=round(scale,6))

def make_memory(tempos):
    bank=deepcopy(read(C/'drills/memory-run-v2.json'))
    bank.update(version=MEMORY,difficultyVersion='memory-performance-v2')
    sources={s['id']:s for s in bank['sources']}
    for s in sources.values():
        if s['collection']=='classical': s.update(tempos[s['id']])
    for e in bank['excerpts']:
        s=sources[e['sourceId']]
        bpm=s.get('quarterBpm',80)
        p=performance(e['raw'],bpm,e['attacks'],e['durationQuarters'],e['shortestQuarter'],'memory')
        e['performance']=p; e['raw']=p['raw']
    for bars in [2,4]:
        cohort=sorted(e['raw'] for e in bank['excerpts'] if e['bars']==bars)
        for e in bank['excerpts']:
            if e['bars']==bars: e['score']=round(100*(bisect.bisect_left(cohort,e['raw'])+bisect.bisect_right(cohort,e['raw']))/2/len(cohort),2)
    previous=read(C/'drills/memory-groove-v1.json')
    policy=dict(previous,version='memory-groove-v2',catalogSha256=sha(raw(bank)))
    return bank,policy

def make_rhythm(tempos):
    old=read(C/'rhythm-puzzle-v3.json');bank=deepcopy(old)
    bank.update(version=RHYTHM,difficulty_version='rhythm-performance-v2')
    accepted=[]; rejected=[]
    for r in bank['rounds']:
        old_id=r['id']; classical=r.get('collection')=='classical'
        if classical:
            t=tempos[r['question_id']]
            r.update(tempo_bpm=t['quarterBpm'],beat_unit=t['tempoBeatUnit'],display_bpm=int(t['tempoDisplayBpm']))
        qn=F(r['total_duration']);audio=r['audio']
        gaps=[F(b['onset'])-F(a['onset']) for a,b in zip(audio,audio[1:])]
        shortest=min(gaps,default=qn)
        p=performance(r['difficulty']['raw'],r['tempo_bpm'],len(audio),qn,shortest,'rhythm')
        reason=None
        if len(audio)<3 and max((F(a['duration']) for a in audio),default=F(0))>=F(r['measure_duration']):
            reason='sustained_without_rhythm_contrast'
        elif p['notesPerSecond']>5 or p['peakNotesPerSecond']>8:
            reason='excessive_attack_rate'
        if reason:
            rejected.append(dict(round_id=old_id,question_id=r['question_id'],title=r['title'],first_measure=r['first_measure'],reason=reason,performance=p))
            continue
        r['source_round_id']=old_id
        r['id']=sha(raw([RHYTHM,old_id,r['tempo_bpm']]))
        r['difficulty'].update(raw=p['raw'],version='rhythm-performance-v2',performance=p)
        accepted.append(r)
    bank['rounds']=accepted
    for r in accepted:
        values=sorted(x['difficulty']['raw'] for x in accepted if x['meter']==r['meter'])
        value=r['difficulty']['raw']
        score=round(100*(bisect.bisect_left(values,value)+bisect.bisect_right(values,value))/2/len(values))
        r['difficulty'].update(score=score,cohort_size=len(values))
        if r.get('collection')=='classical': r['level']='beginner' if score<34 else 'intermediate' if score<67 else 'advanced'
    ink=deepcopy(read(C/'drills/rhythm-engraving-v3.json')); ink['catalog_sha256']=sha(raw(bank))
    return bank,ink,rejected

def make_course(memory,rhythm):
    pools=read(C/'question-pools.json')['records']
    sources={s['id']:s for s in memory['sources']}
    def allowed(s): return s['collection']=='classical' or pools.get(identity(s),{}).get('pool')=='practice'
    candidates=[e for e in memory['excerpts'] if e['bars']==2 and e['pitchRange']>=1 and allowed(sources[e['sourceId']])]
    # Preserve a genuinely novice start and a tiny self-contained demo. These
    # sources already exist in the small pack and all have no key signature.
    demo_ids={e['id'] for e in read(R/'small-demo-memory-run-v2.json')['excerpts'] if e['bars']==2 and e['beginnerEligible']}
    novice=[]; novice_sources=set();novice_patterns=set()
    for e in sorted([e for e in candidates if e['beginnerEligible'] and sources[e['sourceId']].get('fifths')==0],key=lambda e:(e['id'] not in demo_ids,e['raw'],e['id'])):
        if e['sourceId'] in novice_sources or e['fingerprint'] in novice_patterns:continue
        novice.append(e);novice_sources.add(e['sourceId']);novice_patterns.add(e['fingerprint'])
        if len(novice)==8:break
    novice.sort(key=lambda e:(e['raw'],e['id']))
    if len(novice)<8: raise ValueError('Need eight zero-signature novice phrases')
    groups=[novice[:4],novice[4:8]]
    used={e['fingerprint'] for g in groups for e in g}; counts=Counter(e['sourceId'] for g in groups for e in g)
    classical=[e for e in candidates if sources[e['sourceId']]['collection']=='classical']
    values=sorted(e['raw'] for e in classical)
    previous=max(e['raw'] for e in groups[-1])
    for rank in range(3,11):
        cap=CAPS[rank-1];target=values[round((rank-3)/7*.92*(len(values)-1))]
        group=[]
        for _ in range(4):
            available=[e for e in classical if abs(sources[e['sourceId']].get('fifths',99))<=cap and e['fingerprint'] not in used
                       and counts[e['sourceId']]<3 and sum(x['sourceId']==e['sourceId'] for x in group)<2
                       and e['raw']>=previous]
            if not available: raise ValueError(f'No eligible memory excerpt: stage {rank}')
            e=min(available,key=lambda e:(abs(e['raw']-max(target,previous)),counts[e['sourceId']],e['id']))
            group.append(e);used.add(e['fingerprint']);counts[e['sourceId']]+=1
        group.sort(key=lambda e:(e['raw'],e['id']));groups.append(group)
        # Stage means progress; small within-stage overlap stays possible.
        previous=sum(e['raw'] for e in group)/4+1e-8
    rs=[]
    for r in rhythm['rounds']:
        if r.get('collection')!='classical' and pools.get(r['question_id'],{}).get('pool')!='practice':continue
        rs.append(dict(r,sourceId=r['question_id']))
    unique={}
    for r in sorted(rs,key=lambda r:(r['difficulty']['raw'],r['id'])):unique.setdefault((r['meter']['numerator'],r['meter']['denominator'],r['rhythm_key']),r)
    selected=choose_spread(list(unique.values()),50,lambda r:r['difficulty']['raw'],lambda r:(r['meter']['numerator'],r['meter']['denominator'],r['rhythm_key']))
    selected.sort(key=lambda r:(r['difficulty']['raw'],r['id']))
    rhythm_groups=[selected[i:i+5] for i in range(0,50,5)]
    stages=[];ranks=Counter()
    rows={(r['metadata']['id'],r['metadata']['version']):r for r in current_sources(C,include_classical=True)}
    for number in range(1,31):
        game=PATTERN[(number-1)%9]
        if game=='echoDragon':continue
        rank=ranks[game];ranks[game]+=1; questions=[]
        for slot,e in enumerate((groups if game=='memoryRun' else rhythm_groups)[rank],1):
            if game=='memoryRun':
                s=sources[e['sourceId']]
                q=dict(catalog_id=e['id'],source_id=s['id'],question_id=identity(s),source_sha256=s['sha256'],
                    source_file='drills/'+s['file'],collection=s['collection'],title=s['title'],first_measure=e['first'],
                    bpm=s.get('quarterBpm',72+2*rank),key_fifths=s['fifths'],difficulty_score=e['raw'],performance=e['performance'],fingerprint=e['fingerprint'])
                p=performance(e['performance']['baseRaw'],q['bpm'],e['attacks'],e['durationQuarters'],e['shortestQuarter'],'memory')
                q.update(performance=p,difficulty_score=p['raw'])
            else:
                q=dict(catalog_id=e['id'],question_id=e['question_id'],question_version=e['question_version'],source_file=rows[(e['question_id'],e['question_version'])]['main_path'],
                    source_sha256=e['source_xml_sha256'],collection=e['collection'],title=e['title'],first_measure=e['first_measure'],bpm=e['tempo_bpm'],difficulty_score=e['difficulty']['raw'],performance=e['difficulty']['performance'])
            q.update(id=f'{VERSION}-S{number:02}-Q{slot:02}',bars=2);questions.append(q)
        stages.append(dict(number=number,game=game,rank=rank+1,questions=questions))
    return dict(version=VERSION,memory_key_caps=CAPS,stages=stages)

def build():
    tempos=classical_tempos();memory,groove=make_memory(tempos);rhythm,ink,rejected=make_rhythm(tempos)
    course=make_course(memory,rhythm)
    return {MEMORY+'.json':memory,'memory-groove-v2.json':groove,RHYTHM+'.json':rhythm,'rhythm-engraving-v4.json':ink,
            'drill-stage-sets-v2.json':course},dict(policy_version=VERSION,classical_tempos=tempos,rhythm_excluded=rejected)

def main():
    files,report=build()
    for name,value in files.items():
        data=raw(value);freeze(R/name,data)
        freeze(C/name if name==RHYTHM+'.json' else C/'drills'/name,data)
    (ROOT/'docs/drill-curriculum-v2-audit.json').write_bytes(raw(report))
    print('Published',[(name,len(raw(value))) for name,value in files.items()])
    print('Rhythm excluded:',Counter(r['reason'] for r in report['rhythm_excluded']))

if __name__=='__main__':main()
