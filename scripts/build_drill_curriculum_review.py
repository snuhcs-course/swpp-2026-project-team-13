"""Export the current Memory/Rhythm course as reviewable, unchanged MusicXML."""
import argparse
import csv
from copy import deepcopy
import html
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile
import build_drill_curriculum_v2 as b
from build_drill_score_drafts import score_document

def document(title,questions,tempos):
    root=ET.fromstring(score_document(title,questions))
    root.find('identification/source').text='Solfège Memory/Rhythm curriculum v2; unchanged source pitches and rhythms'
    for index,q in enumerate(questions):
        if q['collection']!='classical':continue
        t=tempos[q['question_id']]
        mark=root.findall('part/measure')[index*2].find('direction/direction-type/metronome')
        mark.find('beat-unit').text=t['tempoBeatUnit'].replace('dotted_','')
        if t['tempoBeatUnit'].startswith('dotted_'):mark.insert(1,ET.Element('beat-unit-dot'))
        mark.find('per-minute').text=str(t['tempoDisplayBpm'])
    ET.indent(root)
    return ET.tostring(root,encoding='utf-8',xml_declaration=True)+b'\n'

def build(output):
    output.mkdir(parents=True,exist_ok=True)
    course=b.read(b.C/'drills/drill-stage-sets-v2.json');audit=b.read(b.ROOT/'docs/drill-curriculum-v2-audit.json')
    groups={'memoryRun':[],'rhythmPuzzle':[]};jobs=[];cards=[];rows=[]
    for stage in course['stages']:
        questions=[];game=stage['game'];folder=output/game;folder.mkdir(exist_ok=True)
        for slot,original in enumerate(stage['questions'],1):
            q=deepcopy(original);q.update(id=f'S{stage["number"]:02}-Q{slot:02}',game=game)
            questions.append(q);groups[game].append(q)
            relative=f'{game}/{q["id"]}.xml';(output/relative).write_bytes(document(q['id'],[q],audit['classical_tempos']))
            svg=f'{game}/{q["id"]}.svg';jobs.append({'in':str((output/relative).resolve()),'out':str((output/svg).resolve())})
            cap=b.CAPS[stage['rank']-1] if game=='memoryRun' else None
            rows.append([game,stage['rank'],q['id'],q['title'],q['first_measure'],q.get('key_fifths',''),cap if cap is not None else '',q['bpm'],q['difficulty_score'],q['performance']['notesPerSecond']])
            key=f' · 조표 {abs(q["key_fifths"])}개' if 'key_fifths' in q else ''
            cards.append(f'<article data-game="{game}"><header><b>{game} {stage["rank"]}단계 · {q["id"]}</b><a href="{relative}">MusicXML</a></header><p>{html.escape(q["title"])} · {q["first_measure"]}–{q["first_measure"]+1}마디{key} · ♩={q["bpm"]:g} · 지표 {q["difficulty_score"]:.3f}</p><img loading="lazy" src="{svg}" alt="{q["id"]} 악보"></article>')
        name=f'{game}/S{stage["number"]:02}-all.xml'
        (output/name).write_bytes(document(f'{game} Stage {stage["rank"]}',questions,audit['classical_tempos']))
    for game,questions in groups.items():(output/f'00-{game}-all.xml').write_bytes(document(game,questions,audit['classical_tempos']))
    with (output/'review-order.csv').open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.writer(f);w.writerow(['game','rank','id','title','first_measure','fifths','maximum_fifths','quarter_bpm','difficulty','notes_per_second']);w.writerows(rows)
    (output/'draft-manifest.json').write_bytes(b.raw(course))
    page='''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>미니게임 악보 수정안 v2</title><style>body{background:#f5f5f4;color:#242424;font:16px/1.6 system-ui;margin:0}main{max-width:1100px;margin:auto;padding:24px}nav{position:sticky;top:0;background:#f5f5f4;padding:12px 0}button,a{color:#5241a5}button{padding:8px 16px;margin-right:8px;border:1px solid #ccc;background:white;border-radius:8px}article{background:white;border:1px solid #ddd;padding:20px;margin:18px 0;border-radius:10px}header{display:flex;justify-content:space-between}p{color:#555}img{width:100%;height:auto}</style><main><h1>Memory run · Rhythm puzzle 수정안</h1><p>Memory run 10단계 × 4문제 / Rhythm puzzle 10단계 × 5문제. Echo Dragon은 변경하지 않았습니다.</p><p>Memory 조표 상한: 1–2단계 0개 / 3–4단계 1개 / 5–6단계 2개 / 7–8단계 3개 / 9–10단계 제한 없음.<br>클래식은 지정 템포로 재생·난이도 평가합니다. ♩는 음가를 통일한 속도이며 XML에는 원래 템포 단위도 보존했습니다.</p><p><a href="00-memoryRun-all.xml">Memory 전체 MusicXML</a> · <a href="00-rhythmPuzzle-all.xml">Rhythm 전체 MusicXML</a> · <a href="review-order.csv">검토표 CSV</a></p><nav><button data-filter="all">전체</button><button data-filter="memoryRun">Memory run</button><button data-filter="rhythmPuzzle">Rhythm puzzle</button></nav>'''+''.join(cards)+'''</main><script>document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>document.querySelectorAll('article').forEach(a=>a.hidden=b.dataset.filter!=='all'&&b.dataset.filter!==a.dataset.game));</script></html>'''
    (output/'index.html').write_text(page,encoding='utf-8')
    (output/'render-jobs.json').write_text(json.dumps(jobs),encoding='utf-8')
    return jobs

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=b.ROOT.parent/'output/drill-score-draft-v2');p.add_argument('--render',action='store_true');args=p.parse_args()
    jobs=build(args.output.resolve())
    if args.render:
        command=['C:/Program Files/MuseScore 4/bin/MuseScore4.exe','-platform','offscreen','-S',str(b.ROOT/'scripts/engraving/compact-v1.mss'),'-j',str((args.output/'render-jobs.json').resolve())]
        with (args.output/'render.log').open('w',encoding='utf-8') as log:
            process=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            if process.returncode: print('MuseScore preview unavailable; validated MusicXML files remain available. Exit:',process.returncode)
    with zipfile.ZipFile(args.output.with_suffix('.zip'),'w',compression=zipfile.ZIP_DEFLATED) as z:
        for file in args.output.rglob('*'):
            if file.is_file() and file.suffix not in ['.log']:z.write(file,file.relative_to(args.output))
    print('Review:',args.output/'index.html');print('Individual scores:',len(jobs))
