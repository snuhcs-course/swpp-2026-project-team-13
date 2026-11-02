"""Import the user's Brahms collection without changing existing question versions.

Prepare pinned source excerpts with --prepare-only --score PATH --titles PATH.
Then build_classical_sheets.ps1 -Compact and run this script --render.
Unconfirmed modes, unsupported ornaments and wholly silent blocks are excluded.
"""
import argparse
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
from build_score_previews import prepare

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT/'backend/content'
RESOURCES = ROOT/'frontend/IPadApp/IPadApp/Resources'
SOURCE = CONTENT/'source/brahms'
# Modes describe these excerpts, not the work title's global key. The B-minor
# cadence in excerpt 2 resolves the D-major/B-minor ambiguity of its two sharps.
REVIEWED_MODES = {1:'major',2:'minor',4:'minor',5:'major',7:'major',9:'major',10:'major',11:'major'}
MODE_EVIDENCE = {
    1:'Two sharps; D/F-sharp/A tonic material.',
    2:'Two sharps; F-sharp dominant material, A-sharp leading tone and closing B with rest: local B minor.',
    3:'One sharp; movement is E minor; mode requires confirmation because this chromatic excerpt is ambiguous.',
    4:'One sharp; E-minor melodic material, raised D-sharp and closing E.',
    5:'Four sharps; E-major tonic material; use the excerpt key, not the symphony title E minor.',
    6:'No signature; chromatic excerpt is ambiguous between relative candidates; requires confirmation.',
    7:'Two sharps; D-major tonic material and closing D.',
    9:'Two sharps; D-major fourth-movement context and D/F-sharp/A material.',
    10:'No signature; C-major descending scale and closing C, rather than the work title C minor.',
    11:'One flat; F-major first-movement context and F/A/C material.'
}


def write_json(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


def sha(data): return hashlib.sha256(data).hexdigest()


def normalize(bars,attrs,mode,title):
    div=int(attrs.findtext('divisions')); meter=(int(attrs.findtext('time/beats')),int(attrs.findtext('time/beat-type')))
    fifths=int(attrs.findtext('key/fifths','0')); root,part=build.document(title,*meter)
    for number,original in enumerate(bars,1):
        assert original.get('implicit')!='yes', 'pickup'
        assert not any(original.find(t) is not None for t in ['backup','forward','barline/repeat','barline/ending']), 'polyphony_or_repeat'
        for a in original.findall('attributes'):
            for tag,value in [('divisions',str(div)),('key/fifths',str(fifths)),('time/beats',str(meter[0])),('time/beat-type',str(meter[1]))]:
                assert a.findtext(tag,value)==value, 'changing_key_or_meter'
        bar=build.child(part,'measure',number=str(number))
        if number==1:
            build.attributes(bar,*meter)
            bar.find('attributes/key/fifths').text=str(fifths);bar.find('attributes/key/mode').text=mode
        for sn in original.findall('note'):
            assert sn.find('grace') is None, 'unsupported_grace_notes'
            assert sn.find('chord') is None, 'polyphony'
            note=build.child(bar,'note')
            for el in sn:
                if el.tag in build.NOTE_TAGS: note.append(copy.deepcopy(el))
            ticks=Fraction(int(sn.findtext('duration'))*480,div);assert ticks.denominator==1
            note.find('duration').text=str(ticks.numerator)
            notation=note.find('notations')
            if notation is not None:
                for el in list(notation):
                    if el.tag not in ('tied','tuplet'):notation.remove(el)
                for tuplet in notation.findall('tuplet'):
                    for el in list(tuplet):tuplet.remove(el)
    classical.validate_source(root)
    return root,meter,fifths


def prepare_sources(score,titles,confirm_modes=False):
    assert not (CONTENT/'brahms-catalog.json').exists(), 'Review a new import instead of replacing published questions'
    SOURCE.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(score,SOURCE/'brahms.mscz');shutil.copyfile(titles,SOURCE/'brahms.txt')
    path=SOURCE/'brahms.musicxml'
    subprocess.run([ARGS.musescore,'-o',str(path),str(score.resolve())],check=True,timeout=120,**({'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {}))
    original=ET.parse(path).getroot();assert len(original.findall('part'))==1
    bars=original.findall('part/measure');names=[line.split('. ',1)[1] for line in titles.read_text(encoding='utf-8-sig').splitlines() if line.split('. ',1)[0].isdigit()]
    assert len(names)==11 and len(bars)==106
    accepted=[];excluded=[];attrs=ET.Element('attributes');modes=dict(REVIEWED_MODES)
    if confirm_modes:modes.update({3:'minor',6:'major'})
    for block in range(1,15):
        selected=bars[(block-1)*8:block*8]
        if not selected:break
        start=(block-1)*8+1;end=start+len(selected)-1
        for a in selected[0].findall('attributes'):
            for el in a:
                existing=attrs.find(el.tag)
                if existing is not None:attrs.remove(existing)
                attrs.append(copy.deepcopy(el))
        reason=None
        if not any(n.find('pitch') is not None for b in selected for n in b.findall('note')):reason='all_rests'
        elif len(selected)!=8:reason='not_eight_bars'
        elif any(b.find('note/grace') is not None for b in selected):reason='unsupported_grace_notes'
        elif block not in modes:reason='unconfirmed_mode'
        if reason:
            excluded.append(dict(block=block,measures=[start,end],reason=reason));continue
        mode=modes[block];title='브람스 · '+names[block-1]
        root,meter,fifths=normalize(selected,attrs,mode,title)
        filename=f'brahms-{block:02}.musicxml'
        ET.ElementTree(root).write(SOURCE/filename,encoding='utf-8',xml_declaration=True)
        accepted.append(dict(block=block,measures=[start,end],file=filename,sha256=sha((SOURCE/filename).read_bytes()),title=title,meter=meter,
                             key=dict(fifths=fifths,mode=mode,tonic=(classical.MINOR if mode=='minor' else classical.MAJOR)[fifths+7]),
                             mode_evidence=MODE_EVIDENCE[block],mode_source='user_confirmed' if block in (3,6) else 'reviewed_signature_and_melody',
                             question_id=str(uuid.uuid5(uuid.NAMESPACE_URL,f'https://sori.local/questions/brahms-user-{block:02}'))))
    provenance=dict(source='User-provided classic/brahms.mscz and brahms.txt',source_sha256=sha(score.read_bytes()),xml_sha256=sha(path.read_bytes()),
                    policy='Eight complete source measures; no pitch/rhythm edits, padding, pickup removal, grace removal or inferred global-key substitution.',
                    accepted=accepted,excluded=excluded)
    write_json(SOURCE/'provenance.json',provenance)
    print(f'Prepared {len(accepted)} eight-bar excerpts; exclusions: {excluded}')


def build_assets(render,musescore):
    provenance=json.loads((SOURCE/'provenance.json').read_text(encoding='utf-8'))
    manifest=json.loads((CONTENT/'engraving/manifest.json').read_text(encoding='utf-8'));old=copy.deepcopy(manifest['scores'])
    catalog=[];jobs=[];work=ROOT/'.tmp/brahms-engraving';work.mkdir(parents=True,exist_ok=True)
    for info in provenance['accepted']:
        source=(SOURCE/info['file']).read_bytes();assert sha(source)==info['sha256']
        root=ET.fromstring(source);meter,fifths,mode=classical.validate_source(root);key=info['key'];qid=info['question_id']
        assert key==dict(fifths=fifths,mode=mode,tonic=(classical.MINOR if mode=='minor' else classical.MAJOR)[fifths+7])
        folder=f'questions/brahms-user-{info["block"]:02}/v1';target=CONTENT/folder;target.mkdir(parents=True,exist_ok=True)
        main=build.package(root);scale,count=classical.scale(meter,fifths,mode);assets={}
        for kind,data,bars in [('main',main,8),('scale',scale,count)]:
            (target/(kind+'.mxl')).write_bytes(data);(RESOURCES/f'classical-{qid}-{kind}.mxl').write_bytes(data)
            assets[kind]=dict(url=f'https://api.sori.example/api/v1/questions/{qid}/versions/1/scores/{kind}/',content_type='application/vnd.recordare.musicxml',sha256=sha(data),size_bytes=len(data),musicxml_version='4.0',profile='sori-monophonic-v4',part_id='P1',measure_count=bars,source_tempo_bpm=96)
        layout_id=f'staff-8bars-{meter[0]}-{meter[1]}-key{fifths}-v4';png=(CONTENT/'sheets'/(layout_id+'.png')).read_bytes()
        layout=copy.deepcopy(json.loads((CONTENT/'sheet-revisions.json').read_text(encoding='utf-8'))[0]['metadata']['sheet_layout'])
        layout.update(id=layout_id,template_png_url=f'https://api.sori.example/assets/sheets/{layout_id}.png',template_sha256=sha(png))
        layout_path=CONTENT/'sheets'/(layout_id+'.layout.json')
        if layout_path.exists():assert json.loads(layout_path.read_text(encoding='utf-8'))==layout
        else:write_json(layout_path,layout)
        (RESOURCES/(layout_id+'.pngdata')).write_bytes(png)
        q=dict(id=qid,version=1,title=info['title'],source='practice',collection='classical',composer='브람스',key_signature=key,time_signature=dict(numerator=meter[0],denominator=meter[1]),measure_count=8,recommended_duration_seconds=300,
               description=f'사용자 제공 브람스 악보 {info["measures"][0]}–{info["measures"][1]}마디 발췌입니다. 조표와 발췌 선율에 맞는 음계를 듣고 8마디를 적어보세요.',time_policy='advisory',clef='treble',sheet_layout=layout,content_policy='client_readable_practice',score_visibility='after_submission',score_assets=assets)
        catalog.append(dict(order=1100+info['block'],metadata=q,main_path=folder+'/main.mxl',scale_path=folder+'/scale.mxl'))
        if render:
            path=work/f'brahms-{info["block"]:02}.musicxml';ET.ElementTree(prepare(copy.deepcopy(root))).write(path,encoding='utf-8',xml_declaration=True)
            job={'in':str(path),'out':[str(path.with_suffix('.png')),str(path.with_suffix('.svg'))]}
            if meter==(3,2):job['style']=str(ROOT/'scripts/engraving/brahms-dense-v1.mss')
            jobs.append(job)
    if render:
        options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {}
        version=subprocess.run([musescore,'--long-version'],capture_output=True,text=True,check=True,timeout=30,**options)
        assert '4.6.3' in version.stdout+version.stderr
        for job in jobs:
            for destination in job['out']:
                path=Path(destination)
                for page in (1,2):
                    stale=path.with_name(path.stem+f'-{page}'+path.suffix)
                    assert stale.resolve().is_relative_to(work.resolve())
                    if stale.exists():stale.unlink()
        write_json(work/'jobs.json',jobs)
        subprocess.run([musescore,'-T','12','-r','300','-S',str(ROOT/'scripts/engraving/compact-v1.mss'),'-j',str(work/'jobs.json')],check=True,timeout=240,**options)
        # The batch format has no per-job style override. Re-engrave the dense
        # 3/2 excerpt with smaller staff spacing, preserving every source note.
        for job in jobs:
            if 'style' not in job:continue
            for destination in job['out']:
                path=Path(destination)
                for page in (1,2):
                    stale=path.with_name(path.stem+f'-{page}'+path.suffix)
                    if stale.exists():stale.unlink()
                subprocess.run([musescore,'-T','12','-r','300','-S',job['style'],'-o',destination,job['in']],check=True,timeout=120,**options)
        for info,item in zip(provenance['accepted'],catalog):
            prefix=f'brahms-{info["block"]:02}';name=prefix+'-reference-v1';data=(work/(prefix+'-1.png')).read_bytes();width,height=struct.unpack('>II',data[16:24])
            assert 2000<=width<=3000 and 200<=height<=900,(name,width,height)
            assert not (work/(prefix+'-2.png')).exists(),'Answer must fit one page'
            (CONTENT/'engraving'/(name+'.png')).write_bytes(data);(RESOURCES/(name+'.pngdata')).write_bytes(data)
            shutil.copyfile(work/(prefix+'-1.svg'),CONTENT/'engraving'/(name+'.svg'))
            style='brahms-dense-v1' if tuple(info['meter'])==(3,2) else 'compact-v1'
            manifest['scores'][item['metadata']['score_assets']['main']['sha256']]=dict(resource=name,content_type='image/png',sha256=sha(data),size_bytes=len(data),pixel_width=width,pixel_height=height,renderer=manifest['renderer'],style=style,style_sha256=sha((ROOT/'scripts/engraving'/(style+'.mss')).read_bytes()))
        assert all(manifest['scores'][k]==v for k,v in old.items()),'Existing reference changed'
        write_json(CONTENT/'engraving/manifest.json',manifest);write_json(RESOURCES/'engraving-manifest.json',manifest)
    assert all(q['metadata']['score_assets']['main']['sha256'] in manifest['scores'] for q in catalog),'Generate MuseScore answers with --render first'
    write_json(CONTENT/'brahms-catalog.json',catalog);write_json(RESOURCES/'brahms-catalog.json',[q['metadata'] for q in catalog])
    print(f'Built {len(catalog)} Brahms exams. Previous 124 questions and their versions are unchanged.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only',action='store_true');parser.add_argument('--score',type=Path);parser.add_argument('--titles',type=Path)
    parser.add_argument('--confirm-modes',action='store_true',help='Only after the user confirms excerpt 3 E minor and excerpt 6 C major')
    parser.add_argument('--render',action='store_true');parser.add_argument('--musescore',default='C:/Program Files/MuseScore 4/bin/MuseScore4.exe')
    ARGS=parser.parse_args()
    if ARGS.prepare_only:
        assert ARGS.score and ARGS.titles
        prepare_sources(ARGS.score,ARGS.titles,ARGS.confirm_modes)
    else:build_assets(ARGS.render,ARGS.musescore)
