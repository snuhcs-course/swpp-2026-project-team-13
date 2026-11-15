"""Versioned musical difficulty, separate from source labels and learner scores.

The v1 numerical content model is ported from the reviewed research prototype.
Key-relative spelling, actual pulse duration, and odd-meter grouping are explicit.
Cutoffs use the agreed reference tasks (hobby entry / intermediate / advanced).
These are product calibration anchors, not validated success probabilities.
"""
from collections import Counter
from fractions import Fraction as F
import itertools
import math

from .features.musicxml import decode, FeatureError

VERSION = "practice-difficulty-2"
CUTOFFS = (7.5, 9.5, 13., 30., 55., 62., 68., 74.)
MAJOR_PROFILE = (6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88)
MINOR_PROFILE = (6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17)
DIATONIC = {0,2,4,5,7,9,11}

def entropy(values):
    counts=Counter(values);n=sum(counts.values())
    return -sum(v/n*math.log2(v/n) for v in counts.values()) if n else 0.

def correlation(a,b):
    aa=sum(a)/len(a);bb=sum(b)/len(b)
    denominator=math.sqrt(sum((x-aa)**2 for x in a)*sum((x-bb)**2 for x in b))
    return sum((x-aa)*(y-bb) for x,y in zip(a,b))/denominator if denominator else 0.

def sigmoid(x):
    if x>=0:
        z=math.exp(-x);return 1/(1+z)
    z=math.exp(x);return z/(1+z)

def level_for_score(value):
    if not math.isfinite(value) or value<0:raise ValueError("invalid_difficulty_score")
    # Classification uses the unrounded value. An exact boundary enters the
    # higher level; neither source labels nor live-pool quantiles affect it.
    return 1+sum(value>=edge for edge in CUTOFFS)

def signature_burden(fifths, used_fraction):
    """Signature-reading burden; most remains even when few letters occur."""
    k=abs(fifths)
    return (2*k+.5*k*k)*(.8+.2*used_fraction)

def signature_score_floor(fifths):
    """Entry policy for complete eight-bar tasks, independent of playback speed."""
    k=abs(fifths)
    return 0. if k==0 else CUTOFFS[0] if k==1 else CUTOFFS[1]

def task_score(content, key, tempo_ratio, score_floor=0.):
    return max((content+key)*tempo_ratio,score_floor)

def groups_for(meter):
    n,d=map(int,meter.split('/'))
    if (n,d) in ((5,8),(7,8)):
        return sorted(set(itertools.permutations([2,3] if n==5 else [2,2,3])))
    return [tuple([3]*(n//3) if d==8 and n%3==0 else [1]*n)]

def analyze(raw, *, quarter_bpm, reference_quarter_bpm, first=1, last=None):
    if (not math.isfinite(quarter_bpm) or not math.isfinite(reference_quarter_bpm)
            or min(quarter_bpm,reference_quarter_bpm)<=0):
        raise ValueError("positive_finite_tempo_required")
    measures,events,attacks,diagnostics=decode(raw,"score",{})
    last=len(measures) if last is None else last
    if not 1<=first<=last<=len(measures):raise ValueError("invalid_span")
    selected=measures[first-1:last]
    ee=[e for e in events if first<=e['measure']<=last]
    event_index={e['id']:e for e in events}
    aa=[a for a in attacks if first<=event_index[a['id']]['measure']<=last]
    start=sum((F(m['actual_duration_qn']) for m in measures[:first-1]),F(0))
    end=sum((F(m['actual_duration_qn']) for m in measures[:last]),F(0))
    pulses=0.;sync_count=0;signature_weight=0.;duration_total=F(0);signature_floor=0.
    grouping_evidence=[]
    for m in selected:
        duration=F(m['actual_duration_qn']);expected=F(m['expected_duration_qn'])
        candidates=groups_for(m['meter']);pulses+=len(candidates[0])*float(duration/expected)
        counts=[];n,d=map(int,m['meter'].split('/'))
        for grouping in candidates:
            boundaries=[F(0)]
            for g in grouping:boundaries.append(boundaries[-1]+F(4*g,d))
            count=0
            for a in aa:
                if event_index[a['id']]['measure']!=m['number']:continue
                onset=F(a['onset_qn']);finish=onset+F(a['sounding_duration_qn'])
                if m['number']==last:finish=min(finish,duration)
                if onset not in boundaries and any(onset<b<finish for b in boundaries):count+=1
            counts.append(count)
        sync_count+=min(counts)
        if len(candidates)>1:grouping_evidence.append(dict(measure=m['number'],minimum=min(counts),maximum=max(counts)))
        key=m['key_signature']
        if key is None:raise FeatureError("difficulty_requires_notated_key")
        k=abs(key['fifths']);letters=("FCGDAEB" if key['fifths']>0 else "BEADGCF")[:k]
        used={e['step'] for e in ee if e['measure']==m['number'] and e['kind']=='note' and not e['tie_stop']}
        use=len(used&set(letters))/k if k else 0.
        # Point correction, applied before fixed cutoffs, never a level override.
        signature_weight+=float(duration)*signature_burden(key['fifths'],use)
        signature_floor=max(signature_floor,signature_score_floor(key['fifths']))
        duration_total+=duration
    intervals=[b['midi']-a['midi'] for a,b in zip(aa,aa[1:])]
    hist=[0.]*12
    for a in attacks:
        lo=max(start,F(a['absolute_onset_qn']))
        hi=min(end,F(a['absolute_onset_qn'])+F(a['sounding_duration_qn']))
        if hi>lo:hist[a['midi']%12]+=float(hi-lo)
    fit=max(correlation(hist,[profile[(pc-tonic)%12] for pc in range(12)])
            for profile in (MAJOR_PROFILE,MINOR_PROFILE) for tonic in range(12))
    chromatic=0
    for a in aa:
        m=measures[event_index[a['id']]['measure']-1]
        fifths=m['key_signature']['fifths']
        chromatic+=(a['midi']-7*fifths)%12 not in DIATONIC
    count=len(aa)
    metrics=dict(chromatic=chromatic/count if count else 0.,
        mean_interval=sum(abs(i) for i in intervals)/len(intervals) if intervals else 0.,
        density=count/pulses if pulses else 0.,tonal_weakness=1-max(0.,fit) if count else 0.,
        interval_entropy=entropy(max(-12,min(12,i)) for i in intervals),
        pitch_classes=len({a['midi']%12 for a in aa}),syncopation=sync_count/pulses if pulses else 0.,
        tuplets=sum(event_index[a['id']]['tuplet_ratio']!=[1,1] for a in aa)/count if count else 0.,
        duration_entropy=entropy(a['sounding_duration_qn'] for a in aa))
    A=metrics['interval_entropy']+.7*metrics['pitch_classes']
    B=60*metrics['chromatic']+4*metrics['mean_interval']+8*metrics['density']+30*metrics['tonal_weakness']
    R=2*metrics['syncopation']+metrics['tuplets']+metrics['duration_entropy']/4
    content=(38*sigmoid(5*(A-10))+38*sigmoid(.6*(B-50))+19*B/(B+40)+5*R/(1+R)) if count else 0.
    key_add=signature_weight/float(duration_total) if count and duration_total else 0.
    tempo_ratio=quarter_bpm/reference_quarter_bpm
    # Score-level speed correction: 1.25x playback means 1.25x task index.
    # This is an initial monotonic operating assumption, not an empirical law.
    complete_eight=(first==1 and last==len(measures)==8 and
        all(m['actual_duration_qn']==m['expected_duration_qn'] for m in measures))
    # These floors express entry-level prerequisites for whole questions.
    # Partial-bar indices retain their continuous musical score without them.
    score_floor=signature_floor if complete_eight else 0.
    final=task_score(content,key_add,tempo_ratio,score_floor)
    return dict(version=VERSION,content_score=content,key_correction=key_add,score_floor=score_floor,
        tempo_ratio=tempo_ratio,quarter_bpm=quarter_bpm,reference_quarter_bpm=reference_quarter_bpm,
        score=final,level=level_for_score(final) if complete_eight else None,metrics=metrics,
        components=dict(A=A,B=B,R=R),scope=dict(first_measure=first,last_measure=last),
        grouping_uncertainty=grouping_evidence,diagnostics=diagnostics)
