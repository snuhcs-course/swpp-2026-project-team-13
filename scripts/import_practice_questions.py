"""Import user-verified Pages 1-2 and a varied, nontrivial beginner selection.

First: --prepare-only --pages PATH --library PATH (the 1,047 XML collection).
Then build_classical_sheets.ps1 and this script --render. Later rebuilds use only
the checked-in, hash-pinned sources. The original 62 and classical 11 are immutable.
"""
import argparse
import collections
import copy
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import uuid
import xml.etree.ElementTree as ET

import build_question_assets as build
import build_classical_questions as classical
from import_melody_library import inspect

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT/'backend/content'
RESOURCES = ROOT/'frontend/IPadApp/IPadApp/Resources'
SOURCE = CONTENT/'source/practice-import'
BEGINNER_COUNT = 40


def write_json(path, value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


def normalize(original, bars=None, inherited=None):
    bars = bars if bars is not None else original.findall('part/measure')
    attrs = inherited if inherited is not None else bars[0].find('attributes')
    divisions = int(attrs.findtext('divisions'))
    meter = int(attrs.findtext('time/beats')),int(attrs.findtext('time/beat-type'))
    fifths = int(attrs.findtext('key/fifths','0'))
    # Pages 1-2 has a zero-fifths signature without mode, matching the existing
    # C-major reference scale. Its original and the user's review are retained.
    mode = attrs.findtext('key/mode','major')
    root,part = build.document('Practice',*meter)
    for number,source_bar in enumerate(bars,1):
        assert source_bar.get('implicit') != 'yes', 'Pickups are excluded'
        assert not any(source_bar.find(t) is not None for t in ('backup','forward','barline/repeat','barline/ending'))
        for a in source_bar.findall('attributes'):
            for tag,expected in [('divisions',str(divisions)),('time/beats',str(meter[0])),('time/beat-type',str(meter[1])),('key/fifths',str(fifths)),('key/mode',mode)]:
                assert a.findtext(tag,expected) == expected, 'Changing attributes within an exercise'
        bar = build.child(part,'measure',number=str(number))
        if number == 1:
            build.attributes(bar,*meter)
            bar.find('attributes/key/fifths').text = str(fifths)
            bar.find('attributes/key/mode').text = mode
        for sn in source_bar.findall('note'):
            note = build.child(bar,'note')
            for element in sn:
                if element.tag in build.NOTE_TAGS: note.append(copy.deepcopy(element))
            duration = Fraction(int(sn.findtext('duration'))*480,divisions)
            assert duration.denominator == 1
            note.find('duration').text = str(duration.numerator)
            if note.find('rest') is not None and note.find('type') is None:
                # A full-measure rest has no required written type in source XML.
                # Give it an equivalent, explicit rhythm for the existing parser.
                kind = next((k for k,v in classical.BASES.items() if v == duration),None)
                assert kind, 'Unsupported untyped full-measure rest'
                note.find('rest').attrib.clear()
                build.child(note,'type',kind)
            notation = note.find('notations')
            if notation is not None:
                for element in list(notation):
                    if element.tag not in ('tied','tuplet'): notation.remove(element)
                # Flat adds optional tuplet-actual/normal engraving children.
                # The existing app reads start/stop plus time-modification;
                # its duration/ratio remains unchanged when these are omitted.
                for tuplet in notation.findall('tuplet'):
                    for element in list(tuplet): tuplet.remove(element)
    classical.validate_source(root)
    return root,meter,fifths,mode


def musical_identity(root):
    divisions = int(root.findtext('part/measure/attributes/divisions'))
    return [(n.findtext('pitch/step'),int(n.findtext('pitch/alter','0')),n.findtext('pitch/octave'),
             Fraction(int(n.findtext('duration')),divisions),tuple(t.get('type') for t in n.findall('tie')))
            for n in root.findall('part/measure/note')]


def features(root):
    fifths = int(root.findtext('part/measure/attributes/key/fifths'))
    defaults = {x:1 if fifths>0 else -1 for x in ('FCGDAEB' if fifths>0 else 'BEADGCF')[:abs(fifths)]}
    pitches,lengths = [],[]
    chromatic = triplets = rests = 0
    for note in root.findall('part/measure/note'):
        if note.find('rest') is not None: rests += 1; continue
        p = note.find('pitch'); step = p.findtext('step'); alter = int(p.findtext('alter','0'))
        pitches.append((int(p.findtext('octave'))+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[step]+alter)
        lengths.append(int(note.findtext('duration')))
        chromatic += alter != defaults.get(step,0)
        triplets += note.find('time-modification') is not None
    return dict(notes=len(pitches),pitch_count=len(set(pitches)),span=max(pitches)-min(pitches) if pitches else 0,
                rhythms=len(set(lengths)),shortest=min(lengths,default=0),rests=rests,chromatic=chromatic,triplets=triplets,
                max_leap=max((abs(b-a) for a,b in zip(pitches,pitches[1:])),default=0))


def beginner_rejection(info, fifths):
    if abs(fifths)>3: return 'more_than_three_key_accidentals'
    if info['notes']<20 or info['pitch_count']<5 or info['span']<7 or info['rhythms']<2: return 'too_simple'
    if info['notes']>48 or info['span']>19 or info['shortest']<240 or info['chromatic']>2 or info['triplets']>6 or info['max_leap']>12: return 'beyond_beginner'
    return None


def import_sources(pages, library):
    SOURCE.mkdir(parents=True,exist_ok=True)
    original_bytes = pages.read_bytes(); (SOURCE/'pages-1-2.musicxml').write_bytes(original_bytes)
    original = ET.fromstring(original_bytes); bars = original.findall('part/measure')
    assert len(original.findall('part')) == 1 and len(bars)%8 == 0
    accepted,excluded = [],[]
    attrs = ET.Element('attributes')
    for i,bar in enumerate(bars):
        for a in bar.findall('attributes'):
            for element in a:
                old = attrs.find(element.tag)
                if old is not None: attrs.remove(old)
                attrs.append(copy.deepcopy(element))
        if i%8: continue
        root,meter,fifths,mode = normalize(original,bars[i:i+8],attrs)
        block = i//8+1
        if not any(n.find('pitch') is not None for n in root.findall('part/measure/note')):
            excluded.append(dict(kind='pages',block=block,measures=[i+1,i+8],reason='eight_bars_of_rests')); continue
        accepted.append(dict(kind='pages',source_id=f'pages-1-2-{block:02}',file='pages-1-2.musicxml',sha256=hashlib.sha256(original_bytes).hexdigest(),measures=[i+1,i+8],block=block,difficulty='intermediate',meter=meter,key=dict(tonic=classical.MAJOR[fifths+7],mode=mode,fifths=fifths),review='User confirmed the complete transcription; only the silent eight-bar exercise is excluded.',features=features(root)))
    candidates=[]; rejected=collections.Counter()
    for path in sorted((library/'01_exact_8_bars/MusicXML').rglob('*.xml')):
        try:
            source,_ = inspect(path.read_bytes())
            assert source.findtext('part/measure/attributes/clef/sign','G') == 'G', 'bass_clef'
            root,meter,fifths,mode = normalize(source)
            info = features(root); reason = beginner_rejection(info,fifths)
            if reason: rejected[reason] += 1; continue
            candidates.append(dict(path=path,meter=meter,key=dict(tonic=(classical.MINOR if mode=='minor' else classical.MAJOR)[fifths+7],mode=mode,fifths=fifths),features=info,identity=repr((meter,fifths,mode,musical_identity(root)))))
        except (ValueError,AssertionError,ET.ParseError,TypeError) as error:
            rejected[str(error) or 'unsupported_source_notation'] += 1
    selected=[]; books=collections.Counter(); meters=collections.Counter(); keys=collections.Counter(); modes=collections.Counter(); identities=set()
    while len(selected)<BEGINNER_COUNT:
        pool=[c for c in candidates if c['identity'] not in identities and books[c['path'].parent.name]<8]
        assert pool, 'Not enough distinct validated beginner candidates'
        def priority(c):
            f=c['features']; k=c['key']; book=c['path'].parent.name
            variety=books[book]*6+meters[c['meter']]*3+keys[(k['fifths'],k['mode'])]*2+modes[k['mode']]*0.4
            complexity=abs(f['notes']-30)*0.04+abs(f['span']-12)*0.03+f['chromatic']*0.1
            return variety+complexity,c['path'].name
        c=min(pool,key=priority); selected.append(c); identities.add(c['identity'])
        books[c['path'].parent.name]+=1; meters[c['meter']]+=1; keys[(c['key']['fifths'],c['key']['mode'])]+=1; modes[c['key']['mode']]+=1
    selected.sort(key=lambda c:(c['meter'],c['key']['fifths'],c['path'].name))
    for number,c in enumerate(selected,1):
        path=c['path']; data=path.read_bytes(); filename=path.name; (SOURCE/filename).write_bytes(data)
        accepted.append(dict(kind='trained-ear',source_id='trained-ear-'+path.stem,file=filename,sha256=hashlib.sha256(data).hexdigest(),difficulty='beginner',number=number,meter=c['meter'],key=c['key'],features=c['features'],book=path.parent.name,source_url='https://www.trainedear.net/',license='CC BY-SA 4.0'))
    shutil.copyfile(library/'SOURCES_AND_LICENSE.md',SOURCE/'TRAINED-EAR-LICENSE.md')
    for item in accepted:
        item['question_id']=str(uuid.uuid5(uuid.NAMESPACE_URL,'https://sori.local/questions/'+item['source_id']))
    provenance=dict(pages_source='User supplied Melodic Exercises - Pages 1-2.musicxml; user verified transcription.',
                    beginner_selection=dict(selected=BEGINNER_COUNT,eligible=len(candidates),exact_sources=961,pickups_excluded=86,excluded=dict(rejected),criteria='At least 20 notes, 5 pitches, a perfect-fifth span and 2 rhythms; at most 48 notes, 19 semitones, 3 key accidentals, eighth-note minimum, 2 chromatic notes, 6 tuplet notes, octave maximum leap; diversify books, meters and keys.'),accepted=accepted,excluded=excluded)
    write_json(SOURCE/'provenance.json',provenance)
    print(f'Prepared {sum(x["kind"]=="pages" for x in accepted)} Pages exercises and {BEGINNER_COUNT} beginner exercises; excluded {excluded}.')


def source_score(item):
    data=(SOURCE/item['file']).read_bytes(); assert hashlib.sha256(data).hexdigest()==item['sha256']
    original=ET.fromstring(data)
    if item['kind']=='pages':
        bars=original.findall('part/measure'); first,last=item['measures']; inherited=ET.Element('attributes')
        for bar in bars[:first]:
            for attrs in bar.findall('attributes'):
                for element in attrs:
                    old=inherited.find(element.tag)
                    if old is not None: inherited.remove(old)
                    inherited.append(copy.deepcopy(element))
        return normalize(original,bars[first-1:last],inherited)[0]
    inspect(data)
    root=normalize(original)[0]
    assert musical_identity(root)==musical_identity(original), 'Never alter source pitch, rhythm or tie'
    return root


def build_assets(render, musescore):
    provenance=json.loads((SOURCE/'provenance.json').read_text(encoding='utf-8'))
    manifest=json.loads((CONTENT/'engraving/manifest.json').read_text(encoding='utf-8')); previous=copy.deepcopy(manifest['scores'])
    catalog=[]; jobs=[]; work=ROOT/'.tmp/practice-engraving'; work.mkdir(parents=True,exist_ok=True)
    for index,item in enumerate(provenance['accepted'],1):
        root=source_score(item); meter=tuple(item['meter']); key=item['key']; qid=item['question_id']
        title=(f'중급 청음 · Pages {item["block"]:02}' if item['kind']=='pages' else f'초급 청음 {item["number"]:02}')+f' · {meter[0]}/{meter[1]}'
        root.find('work/work-title').text=title
        folder=f'questions/{item["source_id"]}/v1'; target=CONTENT/folder; target.mkdir(parents=True,exist_ok=True)
        main=build.package(root); scale,count=classical.scale(meter,key['fifths'],key['mode']); assets={}
        for kind,value,bars in [('main',main,8),('scale',scale,count)]:
            (target/(kind+'.mxl')).write_bytes(value); (RESOURCES/f'practice-{qid}-{kind}.mxl').write_bytes(value)
            assets[kind]=dict(url=f'https://api.sori.example/api/v1/questions/{qid}/versions/1/scores/{kind}/',content_type='application/vnd.recordare.musicxml',sha256=hashlib.sha256(value).hexdigest(),size_bytes=len(value),musicxml_version='4.0',profile='sori-monophonic-v4',part_id='P1',measure_count=bars,source_tempo_bpm=96)
        layout_id=f'staff-8bars-{meter[0]}-{meter[1]}-key{key["fifths"]}-v3'; png=(CONTENT/f'sheets/{layout_id}.png').read_bytes()
        (RESOURCES/(layout_id+'.pngdata')).write_bytes(png)
        layout=copy.deepcopy(json.loads((CONTENT/'catalog.json').read_text(encoding='utf-8'))[0]['metadata']['sheet_layout'])
        layout.update(id=layout_id,template_png_url=f'https://api.sori.example/assets/sheets/{layout_id}.png',template_sha256=hashlib.sha256(png).hexdigest())
        layout_path=CONTENT/f'sheets/{layout_id}.layout.json'
        if layout_path.exists(): assert json.loads(layout_path.read_text(encoding='utf-8'))==layout
        else: write_json(layout_path,layout)
        description=(f'Pages 1–2의 {item["measures"][0]}–{item["measures"][1]}마디입니다.' if item['kind']=='pages' else 'The Trained Ear · Andre Mount · CC BY-SA 4.0.')
        q=dict(id=qid,version=1,title=title,source='practice',difficulty=item['difficulty'],key_signature=key,time_signature=dict(numerator=meter[0],denominator=meter[1]),measure_count=8,recommended_duration_seconds=300,description=description+' 음계와 선율을 듣고 조표에 맞춰 8마디를 적어보세요.',time_policy='advisory',clef='treble',sheet_layout=layout,content_policy='client_readable_practice',score_visibility='after_submission',score_assets=assets)
        catalog.append(dict(order=2000+index,metadata=q,main_path=folder+'/main.mxl',scale_path=folder+'/scale.mxl'))
        if render:
            from build_score_previews import prepare
            display=prepare(copy.deepcopy(root)); path=work/(item['source_id']+'.musicxml')
            ET.ElementTree(display).write(path,encoding='utf-8',xml_declaration=True)
            jobs.append({'in':str(path),'out':[str(work/(item['source_id']+'.png')),str(work/(item['source_id']+'.svg'))]})
    if render:
        env=dict(os.environ)
        if os.name!='nt': env.setdefault('QT_QPA_PLATFORM','offscreen')
        options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {}
        version=subprocess.run([musescore,'--long-version'],capture_output=True,text=True,check=True,timeout=30,env=env,**options)
        assert '4.6.3' in version.stdout+version.stderr
        write_json(work/'jobs.json',jobs)
        subprocess.run([musescore,'-T','12','-r','300','-S',str(ROOT/'scripts/engraving/compact-v1.mss'),'-j',str(work/'jobs.json')],check=True,timeout=600,env=env,**options)
        for item,q in zip(provenance['accepted'],catalog):
            name='practice-'+item['source_id']+'-reference-v1'; data=(work/(item['source_id']+'-1.png')).read_bytes(); width,height=struct.unpack('>II',data[16:24])
            assert 2000<=width<=3000 and 200<=height<=750, (name,width,height)
            assert not (work/(item['source_id']+'-2.png')).exists(), 'Answer must fit one page'
            (CONTENT/'engraving'/(name+'.png')).write_bytes(data); (RESOURCES/(name+'.pngdata')).write_bytes(data)
            shutil.copyfile(work/(item['source_id']+'-1.svg'),CONTENT/'engraving'/(name+'.svg'))
            manifest['scores'][q['metadata']['score_assets']['main']['sha256']]=dict(resource=name,content_type='image/png',sha256=hashlib.sha256(data).hexdigest(),size_bytes=len(data),pixel_width=width,pixel_height=height,renderer=manifest['renderer'])
        assert all(manifest['scores'][key]==value for key,value in previous.items()), 'Existing reference changed'
        write_json(CONTENT/'engraving/manifest.json',manifest); write_json(RESOURCES/'engraving-manifest.json',manifest)
    assert all(q['metadata']['score_assets']['main']['sha256'] in manifest['scores'] for q in catalog), 'Run --render first'
    write_json(CONTENT/'additional-practice-catalog.json',catalog); write_json(RESOURCES/'additional-practice-catalog.json',[q['metadata'] for q in catalog])
    print(f'Built {len(catalog)} new exams; original 62 and classical 11 assets preserved.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only',action='store_true'); parser.add_argument('--pages',type=Path); parser.add_argument('--library',type=Path)
    parser.add_argument('--render',action='store_true'); parser.add_argument('--musescore',default='C:/Program Files/MuseScore 4/bin/MuseScore4.exe')
    args=parser.parse_args()
    if args.prepare_only:
        assert args.pages and args.library
        import_sources(args.pages,args.library)
    else: build_assets(args.render,args.musescore)
