"""Publish the user's Mahler excerpts and immutable Brahms tempo revisions.

The question files keep the established normalized notation tempo; playback,
count-ins, scale and duration use the reviewed, original metronome marking.
Existing music, answers, versions, attempts and unrelated app features stay intact.
"""
import argparse
import copy
from fractions import Fraction
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import uuid
import xml.etree.ElementTree as ET

import build_question_assets as build
import build_classical_questions as classical
from build_score_previews import prepare
from import_brahms_questions import normalize, sha, write_json

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
SOURCE=CONTENT/'source/mahler'
SCORE_POLICY='sori-score-tempo-1'
MULTIPLIERS={'quarter':Fraction(1),'dotted_quarter':Fraction(3,2),'half':Fraction(2),'dotted_half':Fraction(3)}
# Block 11 is eight silent measures between the tenth and eleventh melodies.
SOURCE_BLOCKS=[1,2,3,4,5,6,7,8,9,10,12,13,14]
MODES=['minor','minor','minor','major','major','minor','major','major','major','major','minor','major','minor']


def marked_tempo(bars):
    """Read the displayed note value; sound tempo must agree in quarter BPM."""
    found=[]
    for index,bar in enumerate(bars):
        for direction in bar.findall('direction'):
            met=direction.find('direction-type/metronome')
            if met is None:
                assert not any(s.get('tempo') for s in direction.findall('sound')), 'Unlabelled tempo change'
                continue
            note=met.findtext('beat-unit');dots=len(met.findall('beat-unit-dot'))
            unit=('dotted_' if dots else '')+note
            assert dots<=1 and unit in MULTIPLIERS, 'Unsupported source metronome marking'
            value=Fraction(met.findtext('per-minute').strip());assert value.denominator==1 and value>0
            bpm=int(value);quarter=value*MULTIPLIERS[unit];assert 40<=quarter<=200
            sounding=[Fraction(s.get('tempo')) for s in direction.findall('sound') if s.get('tempo')]
            assert sounding==[quarter], 'Printed marking and playback tempo disagree'
            found.append((index,dict(policy_id=SCORE_POLICY,beat_unit=unit,bpm=bpm,minimum_bpm=bpm,maximum_bpm=bpm)))
    assert len(found)==1 and found[0][0]==0, 'Require one fixed marking at the excerpt start'
    return found[0][1]


def prepare_sources(score,titles,exported):
    assert not (SOURCE/'provenance.json').exists(), 'Never replace a reviewed source import'
    SOURCE.mkdir(parents=True,exist_ok=True)
    for path,name in [(score,'mahler.mscz'),(titles,'mahler.txt'),(exported,'mahler.musicxml')]:shutil.copyfile(path,SOURCE/name)
    original=ET.parse(exported).getroot();assert len(original.findall('part'))==1
    bars=original.findall('part/measure');assert len(bars)==138
    names=[line.split('. ',1)[1] for line in titles.read_text(encoding='utf-8-sig').splitlines() if line.split('. ',1)[0].isdigit()]
    assert len(names)==13
    attrs=ET.Element('attributes');accepted=[];excluded=[]
    for block in range(1,19):
        selected=bars[(block-1)*8:block*8];start=(block-1)*8+1;end=start+len(selected)-1
        for a in selected[0].findall('attributes'):
            for element in a:
                old=attrs.find(element.tag)
                if old is not None:attrs.remove(old)
                attrs.append(copy.deepcopy(element))
        if not any(n.find('pitch') is not None for b in selected for n in b.findall('note')):
            excluded.append(dict(block=block,measures=[start,end],reason='all_rests'));continue
        assert len(selected)==8 and block in SOURCE_BLOCKS
        number=SOURCE_BLOCKS.index(block)+1;mode=MODES[number-1];title='말러 · '+names[number-1]
        tempo=marked_tempo(selected);clean=copy.deepcopy(selected)
        # Preserve the sounding duration of a whole-measure rest (bar 80),
        # supplying the explicit type required by the existing score profile.
        for bar in clean:
            for note in bar.findall('note'):
                if note.find('rest') is not None and note.find('type') is None:
                    duration=Fraction(int(note.findtext('duration'))*480,int(attrs.findtext('divisions')))
                    kind=next(k for k,v in classical.BASES.items() if v==duration)
                    note.find('rest').attrib.clear();build.child(note,'type',kind)
        root,meter,fifths=normalize(clean,attrs,mode,title)
        filename=f'mahler-{number:02}.musicxml'
        ET.ElementTree(root).write(SOURCE/filename,encoding='utf-8',xml_declaration=True)
        key=dict(fifths=fifths,mode=mode,tonic=(classical.MINOR if mode=='minor' else classical.MAJOR)[fifths+7])
        accepted.append(dict(number=number,block=block,measures=[start,end],file=filename,sha256=sha((SOURCE/filename).read_bytes()),title=title,meter=meter,key=key,tempo=tempo,
            mode_source='user_confirmed' if number in (7,8,11) else 'reviewed_signature_and_melody',
            question_id=str(uuid.uuid5(uuid.NAMESPACE_URL,f'https://sori.local/questions/mahler-user-{block:02}'))))
    assert len(accepted)==13
    write_json(SOURCE/'provenance.json',dict(source='User-provided classic/mahler.mscz and mahler.txt',source_sha256=sha(score.read_bytes()),xml_sha256=sha(exported.read_bytes()),
        policy='Eight complete source bars; retain notes, rests and ties; exclude only wholly silent blocks; original fixed metronome markings.',accepted=accepted,excluded=excluded))
    print('Prepared 13 complete eight-bar Mahler melodies; silent blocks excluded:',[i['measures'] for i in excluded])


def brahms_tempo_revisions():
    original=ET.parse(CONTENT/'source/brahms/brahms.musicxml').getroot();bars=original.findall('part/measure')
    provenance=json.loads((CONTENT/'source/brahms/provenance.json').read_text(encoding='utf-8'))
    catalog=json.loads((CONTENT/'brahms-catalog.json').read_text(encoding='utf-8'));revisions=[];evidence=[]
    for info,item in zip(provenance['accepted'],catalog):
        assert item['metadata']['id']==info['question_id']
        tempo=marked_tempo(bars[info['measures'][0]-1:info['measures'][1]])
        revision=copy.deepcopy(item);q=revision['metadata'];old=q['version'];q['version']=old+1;q['tempo']=tempo
        for asset in q['score_assets'].values():asset['url']=asset['url'].replace(f'/versions/{old}/',f'/versions/{old+1}/')
        revisions.append(revision);evidence.append(dict(question_id=q['id'],version=q['version'],block=info['block'],measures=info['measures'],tempo=tempo))
    write_json(CONTENT/'classical-tempo-revisions.json',revisions)
    write_json(RESOURCES/'classical-tempo-revisions.json',[i['metadata'] for i in revisions])
    write_json(CONTENT/'source/brahms/tempo-provenance.json',dict(source_sha256=provenance['xml_sha256'],revisions=evidence))
    print('Published 10 Brahms version-2 tempo revisions; original music, references and version 1 unchanged.')


def classical_order_key(question):
    title=question['title']
    def number(pattern,default=0):
        match=re.search(pattern,title,re.IGNORECASE)
        return int(match.group(1)) if match else default
    opus=number(r'Op\.\s*(\d+)',10000)
    movement=number(r'(?:제)?(\d+)\s*악장')
    theme=number(r'(\d+)\s*주제')
    if '교향곡' in title:
        work=(0,number(r'교향곡\s*(?:제)?(\d+)\s*번'),movement,theme,opus)
    elif '협주곡' in title:
        work=(1,number(r'협주곡\s*(?:제)?(\d+)\s*번'),opus,movement,theme)
    elif '소나타' in title:
        work=(2,opus,number(r'No\.\s*(\d+)'),movement,theme)
    else:
        work=(3,opus,number(r'No\.\s*(\d+)'),movement,theme)
    return (question['composer'],work,title,question['id'])


def publish_classical_order():
    questions=[item['metadata'] for filename in ['classical-catalog.json','brahms-catalog.json','mahler-catalog.json']
               for item in json.loads((CONTENT/filename).read_text(encoding='utf-8'))]
    ordered=[q['id'] for q in sorted(questions,key=classical_order_key)]
    assert len(ordered)==len(set(ordered))==34
    write_json(CONTENT/'classical-question-order.json',ordered)
    write_json(RESOURCES/'classical-question-order.json',ordered)
    print('Published natural work/movement order for all 34 classical questions; IDs and old snapshots unchanged.')


def build_assets(render,musescore):
    provenance=json.loads((SOURCE/'provenance.json').read_text(encoding='utf-8'))
    manifest=json.loads((CONTENT/'engraving/manifest.json').read_text(encoding='utf-8'));before=copy.deepcopy(manifest['scores'])
    catalog=[];jobs=[];work=ROOT/'.tmp/mahler-engraving';work.mkdir(parents=True,exist_ok=True)
    for info in provenance['accepted']:
        raw=(SOURCE/info['file']).read_bytes();assert sha(raw)==info['sha256']
        root=ET.fromstring(raw);meter,fifths,mode=classical.validate_source(root);qid=info['question_id']
        folder=f'questions/mahler-user-{info["block"]:02}/v1';target=CONTENT/folder;target.mkdir(parents=True,exist_ok=True)
        main=build.package(root);scale,count=classical.scale(meter,fifths,mode);assets={}
        for kind,data,measures in [('main',main,8),('scale',scale,count)]:
            (target/(kind+'.mxl')).write_bytes(data);(RESOURCES/f'classical-{qid}-{kind}.mxl').write_bytes(data)
            assets[kind]=dict(url=f'https://api.sori.example/api/v1/questions/{qid}/versions/1/scores/{kind}/',content_type='application/vnd.recordare.musicxml',sha256=sha(data),size_bytes=len(data),musicxml_version='4.0',profile='sori-monophonic-v4',part_id='P1',measure_count=measures,source_tempo_bpm=96)
        layout_id=f'staff-8bars-{meter[0]}-{meter[1]}-key{fifths}-v4';png=(CONTENT/'sheets'/(layout_id+'.png')).read_bytes()
        layout=copy.deepcopy(json.loads((CONTENT/'sheet-revisions.json').read_text(encoding='utf-8'))[0]['metadata']['sheet_layout'])
        layout.update(id=layout_id,template_png_url=f'https://api.sori.example/assets/sheets/{layout_id}.png',template_sha256=sha(png))
        path=CONTENT/'sheets'/(layout_id+'.layout.json')
        if path.exists():assert json.loads(path.read_text(encoding='utf-8'))==layout
        else:write_json(path,layout)
        (RESOURCES/(layout_id+'.pngdata')).write_bytes(png)
        q=dict(id=qid,version=1,title=info['title'],source='practice',collection='classical',composer='말러',key_signature=info['key'],time_signature=dict(numerator=meter[0],denominator=meter[1]),measure_count=8,recommended_duration_seconds=300,tempo=info['tempo'],
            description=f'사용자 제공 말러 악보 {info["measures"][0]}–{info["measures"][1]}마디 발췌입니다. 원본에 표시된 빠르기로 음계와 선율을 듣고 8마디를 적어보세요.',time_policy='advisory',clef='treble',sheet_layout=layout,content_policy='client_readable_practice',score_visibility='after_submission',score_assets=assets)
        catalog.append(dict(order=1200+info['number'],metadata=q,main_path=folder+'/main.mxl',scale_path=folder+'/scale.mxl'))
        if render:
            path=work/f'mahler-{info["number"]:02}.musicxml';ET.ElementTree(prepare(copy.deepcopy(root))).write(path,encoding='utf-8',xml_declaration=True)
            jobs.append({'in':str(path),'out':[str(path.with_suffix('.png')),str(path.with_suffix('.svg'))]})
    if render:
        options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {}
        version=subprocess.run([musescore,'--long-version'],capture_output=True,text=True,check=True,timeout=30,**options)
        assert '4.6.3' in version.stdout+version.stderr
        write_json(work/'jobs.json',jobs)
        subprocess.run([musescore,'-T','12','-r','300','-S',str(ROOT/'scripts/engraving/compact-v1.mss'),'-j',str(work/'jobs.json')],check=True,timeout=240,**options)
        for info,item in zip(provenance['accepted'],catalog):
            prefix=f'mahler-{info["number"]:02}';name=prefix+'-reference-v1';data=(work/(prefix+'-1.png')).read_bytes();width,height=struct.unpack('>II',data[16:24])
            assert 2000<=width<=3000 and 200<=height<=900,(name,width,height)
            assert not (work/(prefix+'-2.png')).exists(),'Answer must fit one page'
            (CONTENT/'engraving'/(name+'.png')).write_bytes(data);(RESOURCES/(name+'.pngdata')).write_bytes(data)
            shutil.copyfile(work/(prefix+'-1.svg'),CONTENT/'engraving'/(name+'.svg'))
            svg=ET.parse(CONTENT/'engraving'/(name+'.svg')).getroot();assert len([e for e in svg if e.get('class')=='StaffLines'])==10,'Require two systems'
            manifest['scores'][item['metadata']['score_assets']['main']['sha256']]=dict(resource=name,content_type='image/png',sha256=sha(data),size_bytes=len(data),pixel_width=width,pixel_height=height,renderer=manifest['renderer'])
        assert all(manifest['scores'][k]==v for k,v in before.items()),'Existing reference changed'
        write_json(CONTENT/'engraving/manifest.json',manifest);write_json(RESOURCES/'engraving-manifest.json',manifest)
    assert all(i['metadata']['score_assets']['main']['sha256'] in manifest['scores'] for i in catalog),'Render the answers first'
    write_json(CONTENT/'mahler-catalog.json',catalog);write_json(RESOURCES/'mahler-catalog.json',[i['metadata'] for i in catalog])
    brahms_tempo_revisions()
    publish_classical_order()
    print('Published Mahler 13 + Brahms tempo revisions 10; other problem catalogs and app features unchanged.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only',action='store_true');parser.add_argument('--score',type=Path);parser.add_argument('--titles',type=Path);parser.add_argument('--exported',type=Path)
    parser.add_argument('--render',action='store_true');parser.add_argument('--musescore',default='C:/Program Files/MuseScore 4/bin/MuseScore4.exe')
    args=parser.parse_args()
    if args.prepare_only:
        assert args.score and args.titles and args.exported
        prepare_sources(args.score,args.titles,args.exported)
    else:build_assets(args.render,args.musescore)
