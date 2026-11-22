"""Reorder the fixed Memory course by notation, tempo AND absolute recall load.

Keep every v2 score/catalog immutable and all forty selected Memory excerpts.
Rhythm questions and their order are unchanged. New versioned question IDs keep
old completed attempts distinct from the reordered course.
"""
from copy import deepcopy
import build_drill_curriculum_v2 as b

VERSION='drill-stage-sets-3'
NOTE_CAPS=[4,4,10,10,12,12,16,16,24,24]

def recall_score(question,excerpt):
    # Eight attacks in two bars form the neutral reference. Extra entries add
    # independent recall/input load even when their contour is predictable.
    return round(question['difficulty_score']+0.04*max(0,excerpt['attacks']-8),8)

def build():
    course=deepcopy(b.read(b.C/'drills/drill-stage-sets-v2.json'))
    bank=b.read(b.C/'drills/memory-run-v3.json')
    excerpts={e['id']:e for e in bank['excerpts']}
    stages=[s for s in course['stages'] if s['game']=='memoryRun']
    remaining=[]
    for stage in stages[2:]:
        for question in stage['questions']:
            e=excerpts[question['catalog_id']]
            question['notation_difficulty_score']=question['difficulty_score']
            question['note_count']=e['attacks']
            question['difficulty_score']=recall_score(question,e)
            remaining.append(question)
    for rank,stage in enumerate(stages[2:],3):
        eligible=[q for q in remaining if abs(q['key_fifths'])<=b.CAPS[rank-1] and q['note_count']<=NOTE_CAPS[rank-1]]
        chosen=sorted(eligible,key=lambda q:(q['difficulty_score'],q['note_count'],q['catalog_id']))[:4]
        if len(chosen)!=4: raise ValueError(f'Not enough eligible excerpts at Memory stage {rank}')
        stage['questions']=chosen
        for question in chosen: remaining.remove(question)
    if remaining: raise ValueError('Every previous Memory excerpt must be retained')
    course.update(version=VERSION,memory_note_caps=NOTE_CAPS,
                  memory_recall_policy={'neutral_attacks':8,'extra_attack_weight':0.04})
    for stage in course['stages']:
        for slot,question in enumerate(stage['questions'],1):
            question['id']=f'{VERSION}-S{stage["number"]:02}-Q{slot:02}'
    return course

def main():
    course=build();data=b.raw(course)
    for path in [b.C/'drills/drill-stage-sets-v3.json',b.R/'drill-stage-sets-v3.json']: b.freeze(path,data)
    print('Published Memory recall-load revision; Rhythm order unchanged.')

if __name__=='__main__': main()
