"""Create an editable, unpublished 30-stage MusicXML review pack.

This deliberately does not update a runtime catalog, immutable content, or the
device bundle. Approve/reorder the draft first, then publish a new course version.
"""
from collections import Counter
from copy import deepcopy
from fractions import Fraction as F
import argparse
import hashlib
import html
import json
from pathlib import Path
import sys
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / 'backend/content'
sys.path.insert(0, str(ROOT / 'backend'))
from solfege.features.musicxml import read_xml, parse_xml
from solfege.rhythm import current_sources

PATTERN = ['echoDragon', 'memoryRun', 'rhythmPuzzle', 'echoDragon',
           'rhythmPuzzle', 'memoryRun', 'memoryRun', 'echoDragon', 'rhythmPuzzle']
TITLES = dict(memoryRun='Memory run', rhythmPuzzle='Rhythm puzzle', echoDragon='Echo Dragon')
COUNTS = dict(memoryRun=4, rhythmPuzzle=5, echoDragon=6)
ECHO_PLAN = [
    ('같은 음·온음', [0, 0, 2, 2, 2, 2]),
    ('반음·3도', [1, 1, 3, 3, 4, 4]),
    ('4도와 가까운 음정', [5, 5, 3, 4, 2, 1]),
    ('5도까지 넓히기', [7, 7, 5, 5, 3, 4]),
    ('증4도·감5도 구별', [6, 6, 7, 7, 5, 5]),
    ('단6도·장6도', [8, 8, 9, 9, 7, 5]),
    ('단7도·장7도', [10, 10, 11, 11, 9, 8]),
    ('옥타브와 큰 도약', [12, 12, 10, 11, 9, 7]),
    ('좁은 음정·넓은 음정 섞기', [1, 4, 6, 8, 10, 12]),
    ('음정 종합', [2, 3, 5, 7, 11, 12]),
]
INTERVALS = ['같은 음', '단2도', '장2도', '단3도', '장3도', '완전4도',
             '증4도/감5도', '완전5도', '단6도', '장6도', '단7도', '장7도', '옥타브']


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def identity(source):
    if source['collection'] == 'library':
        return str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://sori.local/practice-bank/trained-ear/' + source['id']))
    return source['id']


def midi(note):
    pitch = note.find('pitch')
    if pitch is None:
        return None
    return ((int(pitch.findtext('octave')) + 1) * 12
            + dict(C=0, D=2, E=4, F=5, G=7, A=9, B=11)[pitch.findtext('step')]
            + int(pitch.findtext('alter', '0')))


def choose_spread(candidates, count, score, fingerprint, max_source=2):
    """Sample the available range with source/phrase diversity, deterministically."""
    ordered = sorted(candidates, key=lambda x: (score(x), x['id']))
    chosen, used, sources = [], set(), Counter()
    for index in range(count):
        target = score(ordered[round(index * (len(ordered) - 1) / max(1, count - 1))])
        available = [x for x in ordered if fingerprint(x) not in used and sources[x['sourceId']] < max_source]
        if not available:
            raise ValueError('Not enough independent score excerpts')
        pick = min(available, key=lambda x: (abs(score(x)-target), sources[x['sourceId']], x['id']))
        chosen.append(pick); used.add(fingerprint(pick)); sources[pick['sourceId']] += 1
    return chosen


def memory_questions(memory, sources, allowed):
    candidates = [e for e in memory['excerpts'] if e['bars'] == 2 and e['pitchRange'] >= 2
                  and allowed(sources[e['sourceId']])]
    classical = [e for e in candidates if sources[e['sourceId']]['collection'] == 'classical']
    # Mostly classical, with eight Practice comparisons. The existing metric
    # orders short-term pitch memory; it is not a calibrated learner rating.
    chosen = choose_spread(classical, 32, lambda e:e['raw'], lambda e:e['fingerprint'])
    practice = [e for e in candidates if sources[e['sourceId']]['collection'] != 'classical'
                and 3 <= e['attacks'] <= 16 and e['pitchRange'] <= 17
                and e['chromaticShare'] == 0 and abs(sources[e['sourceId']].get('fifths',0)) <= 1]
    used = {e['fingerprint'] for e in chosen}
    chosen += choose_spread([e for e in practice if e['fingerprint'] not in used], 8,
                            lambda e:e['raw'], lambda e:e['fingerprint'], max_source=1)
    chosen.sort(key=lambda e:(e['raw'], e['id']))
    result = []
    for e in chosen:
        s = sources[e['sourceId']]
        result.append(dict(catalog_id=e['id'], source_id=s['id'], question_id=identity(s),
                           title=s['title'], collection=s['collection'], source_file='drills/'+s['file'],
                           source_sha256=s['sha256'], first_measure=e['first'], bars=2,
                           difficulty=e['raw'], score=e['score'], attacks=e['attacks'],
                           pitch_range=e['pitchRange'], fingerprint=e['fingerprint']))
    return [result[i:i+4] for i in range(0, 40, 4)]


def rhythm_questions(catalog, pools, source_rows):
    candidates = []
    for r in catalog['rounds']:
        if r['collection'] != 'classical' and pools.get(r['question_id'], {}).get('pool') != 'practice':
            continue
        row = source_rows[(r['question_id'], r['question_version'])]
        candidates.append(dict(r, sourceId=r['question_id'], source_file=row['main_path']))
    # Keep each two-bar sound pattern once, including meter in the key.
    unique = {}
    for r in sorted(candidates, key=lambda r:(r['difficulty']['raw'], r['id'])):
        key = (r['meter']['numerator'], r['meter']['denominator'], r['rhythm_key'])
        unique.setdefault(key, r)
    chosen = choose_spread(list(unique.values()), 50, lambda r:r['difficulty']['raw'],
                           lambda r:(r['meter']['numerator'], r['meter']['denominator'], r['rhythm_key']), max_source=2)
    chosen.sort(key=lambda r:(r['difficulty']['raw'], r['id']))
    result = []
    for r in chosen:
        parts = r['difficulty']['components']
        kinds = sorted({f['code'] for f in r['features'] if f.get('code') in
                        ['rest', 'dotted', 'tuplet', 'tie', 'syncopation', 'offbeat']})
        result.append(dict(catalog_id=r['id'], question_id=r['question_id'], title=r['title'],
                           collection=r['collection'], question_version=r['question_version'],
                           source_file=r['source_file'], source_sha256=r['source_xml_sha256'],
                           first_measure=r['first_measure'], bars=2, difficulty=r['difficulty']['raw'],
                           score=r['difficulty']['score'], rhythm_key=r['rhythm_key'],
                           components=parts, kinds=kinds, ties=len(r['solution_ties']),
                           audio=r['audio'], meter=r['meter']))
    return [result[i:i+5] for i in range(0, 50, 5)]


def echo_questions(sources, allowed):
    candidates = []
    for s in sources.values():
        if not allowed(s):
            continue
        root = parse_xml((CONTENT/'drills'/s['file']).read_bytes())
        for measure in root.findall('part/measure'):
            notes = measure.findall('note')
            for index, (a, b) in enumerate(zip(notes, notes[1:]), 1):
                pitches = [midi(a), midi(b)]
                if any(p is None or not 60 <= p <= 84 for p in pitches):
                    continue
                if a.find("tie[@type='stop']") is not None or b.find("tie[@type='stop']") is not None:
                    continue
                distance = pitches[1]-pitches[0]
                if abs(distance) > 12:
                    continue
                candidates.append(dict(id=f"{s['id']}:{measure.attrib['number']}:{index}",
                    source_id=s['id'], question_id=identity(s), title=s['title'], collection=s['collection'],
                    source_file='drills/'+s['file'], source_sha256=s['sha256'],
                    first_measure=int(measure.attrib['number']), note_indices=[index,index+1],
                    notes=pitches, interval=distance,
                    pitches=[ET.tostring(n.find('pitch'), encoding='unicode') for n in [a,b]]))
    used, source_counts, stages = set(), Counter(), []
    for rank, (_, targets) in enumerate(ECHO_PLAN, 1):
        group = []
        for slot, target in enumerate(targets):
            direction = 1 if slot % 2 == 0 else -1
            available = [p for p in candidates if abs(p['interval']) == target and
                         (target == 0 or p['interval']*direction > 0) and tuple(p['notes']) not in used]
            if not available:
                raise ValueError(f'No literal source pair for echo stage {rank}, interval {target}, direction {direction}')
            pick = deepcopy(min(available, key=lambda p:(
                source_counts[p['source_id']], p['collection'] != 'classical',
                abs(sum(p['notes'])/2-68), p['id'])))
            used.add(tuple(pick['notes'])); source_counts[pick['source_id']] += 1
            pick['interval_label'] = INTERVALS[target]
            pick['difficulty'] = target
            group.append(pick)
        stages.append(group)
    return stages


def excerpt(question):
    raw = read_xml(CONTENT/question['source_file'])
    if sha(raw) != question['source_sha256']:
        raise ValueError('Source changed: '+question['source_file'])
    root = parse_xml(raw)
    measures = root.findall('part/measure')
    start = question['first_measure']-1
    attributes = ET.Element('attributes')
    active = {}
    for measure in measures[:start+1]:
        for node in measure.findall('attributes/*'):
            active[node.tag] = deepcopy(node)
    for name in ['divisions', 'key', 'time', 'staves', 'clef', 'transpose']:
        if name in active:
            attributes.append(active[name])
    result = deepcopy(measures[start:start+2])
    if len(result) != 2:
        raise ValueError('Excerpt must have exactly two bars')
    for measure in result:
        for node in list(measure):
            if node.tag in ['print', 'direction', 'barline']:
                measure.remove(node)
        measure.attrib.clear()
        for node in measure.iter():
            for key in ['default-x', 'default-y', 'relative-x', 'relative-y']:
                node.attrib.pop(key, None)
    previous = result[0].find('attributes')
    if previous is not None:
        result[0].remove(previous)
    result[0].insert(0, attributes)
    return result


def echo_measures(question):
    measure = ET.Element('measure')
    attributes = ET.SubElement(measure, 'attributes')
    ET.SubElement(attributes, 'divisions').text = '480'
    ET.SubElement(ET.SubElement(attributes, 'key'), 'fifths').text = '0'
    time = ET.SubElement(attributes, 'time')
    ET.SubElement(time, 'beats').text = '2'; ET.SubElement(time, 'beat-type').text = '4'
    clef = ET.SubElement(attributes, 'clef')
    ET.SubElement(clef, 'sign').text = 'G'; ET.SubElement(clef, 'line').text = '2'
    for text in question['pitches']:
        note = ET.SubElement(measure, 'note'); pitch = ET.fromstring(text); note.append(pitch)
        ET.SubElement(note, 'duration').text = '480'
        ET.SubElement(note, 'type').text = 'quarter'
        alteration = int(pitch.findtext('alter', '0'))
        if alteration:
            ET.SubElement(note, 'accidental').text = {-2:'flat-flat',-1:'flat',1:'sharp',2:'double-sharp'}[alteration]
    return [measure]


def score_document(title, questions, labels=True):
    root = ET.Element('score-partwise', version='4.0')
    ET.SubElement(ET.SubElement(root, 'work'), 'work-title').text = title
    identification = ET.SubElement(root, 'identification')
    ET.SubElement(identification, 'source').text = 'Solfège stage review draft v1; sources in draft-manifest.json'
    part_list = ET.SubElement(root, 'part-list')
    part_info = ET.SubElement(part_list, 'score-part', id='P1')
    ET.SubElement(part_info, 'part-name').text = 'Piano'
    instrument = ET.SubElement(part_info, 'score-instrument', id='I1')
    ET.SubElement(instrument, 'instrument-name').text = 'Acoustic Grand Piano'
    midi_info = ET.SubElement(part_info, 'midi-instrument', id='I1')
    ET.SubElement(midi_info, 'midi-channel').text = '1'; ET.SubElement(midi_info, 'midi-program').text = '1'
    part = ET.SubElement(root, 'part', id='P1')
    number = 0
    for question in questions:
        measures = echo_measures(question) if question['game'] == 'echoDragon' else excerpt(question)
        first = measures[0]
        first.insert(0, ET.Element('print', {'new-system':'yes'}))
        direction = ET.SubElement(first, 'direction', placement='above')
        if labels:
            ET.SubElement(ET.SubElement(direction, 'direction-type'), 'words').text = question['id']
        metronome = ET.SubElement(ET.SubElement(direction, 'direction-type'), 'metronome')
        ET.SubElement(metronome, 'beat-unit').text = 'quarter'
        ET.SubElement(metronome, 'per-minute').text = str(question['bpm'])
        ET.SubElement(direction, 'sound', tempo=str(question['bpm']))
        # Directions belong before notes for playback from beat zero.
        first.remove(direction)
        insertion = next((i for i,node in enumerate(first) if node.tag=='note'),len(first))
        first.insert(insertion, direction)
        for measure in measures:
            number += 1; measure.attrib['number'] = str(number); part.append(measure)
        barline = ET.SubElement(measures[-1], 'barline', location='right')
        ET.SubElement(barline, 'bar-style').text = 'light-heavy' if question is questions[-1] else 'light-light'
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)+b'\n'


def build(output):
    output.mkdir(parents=True, exist_ok=True)
    memory = read(CONTENT/'drills/memory-run-v2.json')
    sources = {s['id']:s for s in memory['sources']}
    pools = read(CONTENT/'question-pools.json')['records']
    def allowed(s):
        return s['collection'] == 'classical' or pools.get(identity(s), {}).get('pool') == 'practice'
    rows = {(r['metadata']['id'],r['metadata']['version']):r for r in current_sources(CONTENT, include_classical=True)}
    groups = dict(memoryRun=memory_questions(memory,sources,allowed),
                  rhythmPuzzle=rhythm_questions(read(CONTENT/'rhythm-puzzle-v3.json'),pools,rows),
                  echoDragon=echo_questions(sources,allowed))
    ranks, stages = Counter(), []
    for number in range(1,31):
        game = PATTERN[(number-1)%9]; rank = ranks[game]; ranks[game] += 1
        stage = dict(number=number, game=game, rank=rank+1, title=TITLES[game],
                     focus=ECHO_PLAN[rank][0] if game == 'echoDragon' else
                           '2마디 선율 기억' if game == 'memoryRun' else '점차 복잡해지는 리듬', questions=[])
        directory = output/game; directory.mkdir(exist_ok=True)
        for slot, original in enumerate(groups[game][rank],1):
            question = deepcopy(original)
            question.update(id=f'S{number:02}-Q{slot:02}', game=game, stage=number, slot=slot,
                            bpm=88 if game == 'echoDragon' else 72+2*rank if game == 'memoryRun' else
                                82.5 if original['meter']['denominator']==8 else 80)
            path = f'{game}/{question["id"]}.xml'; question['xml'] = path
            (output/path).write_bytes(score_document(question['id'],[question],labels=False))
            stage['questions'].append(question)
        stage['xml'] = f'{game}/S{number:02}-all.xml'
        (output/stage['xml']).write_bytes(score_document(f'S{number:02} - {TITLES[game]}',stage['questions']))
        stages.append(stage)
    manifest = dict(version='drill-score-draft-1', status='review_only',
                    memory_bars=2, counts=COUNTS, stages=stages)
    for game,title in TITLES.items():
        questions = [q for s in stages if s['game']==game for q in s['questions']]
        (output/f'00-{game}-all.xml').write_bytes(score_document(title+' - draft',questions))
    (output/'draft-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    lines = ['stage,game,question_id,source_title,source_measure,decision,new_stage,new_order,comment']
    import csv, io
    buffer = io.StringIO(); writer = csv.writer(buffer); writer.writerow(lines[0].split(','))
    for stage in stages:
        for q in stage['questions']:
            writer.writerow([stage['number'],stage['title'],q['id'],q['title'],q['first_measure'],'','','',''])
    (output/'review-order.csv').write_text(buffer.getvalue(),encoding='utf-8-sig')
    jobs = [dict(**{'in':str((output/q['xml']).resolve())},out=str((output/q['xml']).with_suffix('.svg').resolve()))
            for stage in stages for q in stage['questions']]
    (output/'musescore-jobs.json').write_text(json.dumps(jobs,ensure_ascii=False,indent=2),encoding='utf-8')
    write_review(output,manifest)
    return manifest


def write_review(output,manifest):
    blocks = []
    for stage in manifest['stages']:
        cards = []
        for q in stage['questions']:
            detail = (f"{q['interval_label']} · {'상행' if q['interval']>0 else '하행' if q['interval']<0 else '반복'} · MIDI {q['notes']}"
                      if q['game']=='echoDragon' else f"2마디 · {q.get('attacks',len(q.get('audio',[])))}음 · 선정 지표 {q['difficulty']:.3f}")
            svg = q['xml'].replace('.xml','-1.svg')
            cards.append(f'<article><header><b>{q["id"]}</b><a href="{q["xml"]}" download>MusicXML</a></header>'
                         f'<div>{html.escape(q["title"])} · 원본 {q["first_measure"]}마디부터</div>'
                         f'<small>{html.escape(detail)}</small><img loading="lazy" src="{svg}" alt="{q["id"]} 악보"></article>')
        blocks.append(f'<section data-game="{stage["game"]}" id="S{stage["number"]:02}">'
                      f'<h2>S{stage["number"]:02} · {stage["title"]} {stage["rank"]}</h2>'
                      f'<p>{stage["focus"]} · <a href="{stage["xml"]}" download>스테이지 전체 MusicXML</a></p>'+''.join(cards)+'</section>')
    page = '''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>미니게임 악보 초안 · Solfège</title><style>
*{box-sizing:border-box}body{margin:0;background:#f5f5f3;color:#222;font:16px/1.6 system-ui,sans-serif}
main{max-width:1100px;margin:auto;padding:32px 20px}h1{font-size:28px;margin-bottom:8px}h2{font-size:22px}
nav{position:sticky;top:0;background:#f5f5f3ee;padding:12px 0;backdrop-filter:blur(8px);z-index:2}
button,a{color:#4338a8}button{border:1px solid #d9d8e2;background:white;border-radius:8px;padding:9px 14px;margin:3px;cursor:pointer}
button.active{background:#4338a8;color:white}section{margin:32px 0 54px;scroll-margin-top:85px}
article{background:white;border:1px solid #ddd;border-radius:10px;margin:16px 0;padding:16px 22px;overflow:hidden}
article header{display:flex;justify-content:space-between}small{color:#606067}img{display:block;width:100%;height:auto;margin-top:12px}
.note{border-left:3px solid #aaa;padding-left:15px;color:#555}.empty{padding:30px;color:#777}a{margin-left:8px}
@media print{nav{display:none}article{break-inside:avoid}body{background:white}}
</style><main><h1>미니게임 스테이지 악보 초안</h1>
<p>30스테이지 · Memory run 40문제 / Rhythm puzzle 50문제 / Echo Dragon 60문제</p>
<p class="note">검토용 초안입니다. 아직 앱의 문제 구성에는 적용하지 않았습니다.<br>
Memory run은 전부 2마디이며 40문제 중 32문제를 클래식에서 골랐습니다.<br>
S02-Q03처럼 번호로 의견을 알려주면 순서 변경·교체가 가능합니다. XML은 MuseScore에서 직접 수정하고 재생할 수 있습니다.<br>
스테이지 전체 XML은 여러 문제를 한 파일에 모은 검토본입니다. 게임에서는 각 문제를 따로 재생합니다.<br>
선정 지표는 기존 게임용 휴리스틱이며 실제 학습 난이도로 검증된 점수가 아닙니다.</p>
<p>전체 악보: <a href="00-memoryRun-all.xml" download>Memory run XML</a><a href="00-rhythmPuzzle-all.xml" download>Rhythm puzzle XML</a><a href="00-echoDragon-all.xml" download>Echo Dragon XML</a></p>
<nav><button class="active" data-filter="all">전체</button><button data-filter="memoryRun">Memory run</button><button data-filter="rhythmPuzzle">Rhythm puzzle</button><button data-filter="echoDragon">Echo Dragon</button><a href="review-order.csv" download>검토표 CSV</a></nav>
''' + ''.join(blocks) + '''</main><script>
document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{document.querySelectorAll('[data-filter]').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('section').forEach(s=>s.hidden=b.dataset.filter!=='all'&&s.dataset.game!==b.dataset.filter)});
document.querySelectorAll('img').forEach(i=>i.onerror=()=>{const p=document.createElement('p');p.className='empty';p.textContent='미리보기가 없으면 위 MusicXML 파일을 MuseScore에서 열어주세요.';i.replaceWith(p)});
</script></html>'''
    (output/'index.html').write_text(page,encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT.parent/'output/drill-score-draft-v1')
    args = parser.parse_args()
    result = build(args.output.resolve())
    print('Draft stages:',len(result['stages']))
    print('Questions:',dict(Counter(q['game'] for s in result['stages'] for q in s['questions'])))
    print('Review:',(args.output/'index.html').resolve())
