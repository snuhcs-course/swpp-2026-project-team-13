"""Import the collected non-classical bank and calculate one common score.

prepare: inventory workspace sources; preserve original bytes in a pinned archive.
render: generate new reference PNGs only (resumable, bounded batches).
publish: validate every asset and publish catalogs/difficulty manifest together.
"""
from __future__ import annotations
import argparse, collections, copy, csv, hashlib, io, json, math, os, shutil, struct
import subprocess, sys, uuid, zipfile
from fractions import Fraction as F
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1];WORKSPACE=ROOT.parent
CONTENT=ROOT/'backend/content';RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
SOURCE=CONTENT/'source/practice-bank';WORK=ROOT/'.tmp/practice-bank'
sys.path.insert(0,str(ROOT/'backend'))
from solfege.difficulty import analyze, CUTOFFS, VERSION
from solfege.features.musicxml import decode, parse_xml, read_xml
import build_question_assets as build
from build_classical_questions import scale, MAJOR, MINOR
from build_score_previews import prepare as prepare_display
from solfege.playback import resolve_tempo, quarter_bpm, timed_question

def sha(raw):return hashlib.sha256(raw).hexdigest()
def write_json(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n',encoding='utf8')
def read_json(path):return json.loads(path.read_text(encoding='utf8'))

def current_existing():
    result={}
    for name in ('catalog.json','additional-practice-catalog.json','sheet-revisions.json'):
        for row in read_json(CONTENT/name):
            q=row['metadata']
            if q.get('collection')=='classical':continue
            if q['id'] not in result or q['version']>result[q['id']]['metadata']['version']:result[q['id']]=row
    return list(result.values())

def identity(raw):
    mm,ee,aa,_=decode(raw,'identity',{})
    return sha(json.dumps([[a['midi'],a['absolute_onset_qn'],a['sounding_duration_qn']] for a in aa],separators=(',',':')).encode()+
        json.dumps([(m['meter'],m['actual_duration_qn'],m['key_signature']) for m in mm],sort_keys=True).encode())

def app_normalize(raw):
    mm,ee,aa,diag=decode(raw,'import',{})
    if len(mm)!=8 or any(m['actual_duration_qn']!=m['expected_duration_qn'] for m in mm):raise ValueError('pickup_or_incomplete_measure')
    root=parse_xml(raw);attrs=root.find('part/measure/attributes')
    if attrs.findtext('clef/sign','G')!='G' or attrs.findtext('clef/line','2')!='2':raise ValueError('unsupported_clef')
    meters={m['meter'] for m in mm};keys={json.dumps(m['key_signature'],sort_keys=True) for m in mm}
    if len(meters)!=1 or len(keys)!=1 or mm[0]['key_signature'] is None:raise ValueError('changing_or_missing_key_or_meter')
    n,d=map(int,mm[0]['meter'].split('/'));fifths=mm[0]['key_signature']['fifths'];mode=mm[0]['key_signature']['mode']
    if mode not in ('major','minor'):
        if fifths:raise ValueError('unknown_mode_with_key_signature')
        mode='none'
    normalized,part=build.document('Practice bank',n,d)
    event_number=0
    for mi,source in enumerate(root.findall('part/measure'),1):
        if source.find('barline/repeat') is not None or source.find('barline/ending') is not None:raise ValueError('repeat_requires_performance_expansion')
        bar=build.child(part,'measure',number=str(mi))
        if mi==1:
            build.attributes(bar,n,d);bar.find('attributes/key/fifths').text=str(fifths);bar.find('attributes/key/mode').text=mode
        for sn in source.findall('note'):
            e=ee[event_number];event_number+=1
            if e['kind']=='note' and not 48<=e['midi']<=95:raise ValueError('outside_supported_piano_range')
            if e['tuplet_ratio'] not in ([1,1],[3,2]):raise ValueError('unsupported_tuplet_ratio')
            ticks=F(e['duration_qn'])*480
            if ticks.denominator!=1:raise ValueError('duration_not_exact_at_480ppq')
            note=build.child(bar,'note')
            for el in sn:
                if el.tag in build.NOTE_TAGS:note.append(copy.deepcopy(el))
            for tag in ('voice','staff'):
                for el in note.findall(tag):el.text='1'
            note.find('duration').text=str(int(ticks))
            # A source's complete measure rest may omit note type. Express its
            # exact duration explicitly; never add, remove, or round silence.
            if note.find('type') is None or (e['kind']=='rest' and note.find('rest').get('measure')=='yes'):
                for el in list(note):
                    if el.tag in ('type','dot'):note.remove(el)
                if e['kind']=='rest':note.find('rest').attrib.clear()
                found=None
                for typ,b in [('whole',1920),('half',960),('quarter',480),('eighth',240),('16th',120),('32nd',60)]:
                    for dots in range(3):
                        if F(b)*sum((F(1,2**i) for i in range(dots+1)),F(0))*F(e['tuplet_ratio'][1],e['tuplet_ratio'][0])==ticks:found=(typ,dots);break
                    if found:break
                if not found:raise ValueError('unsupported_explicit_rest_or_note_duration')
                build.child(note,'type',found[0])
                for _ in range(found[1]):build.child(note,'dot')
            if note.findtext('type') not in ('whole','half','quarter','eighth','16th','32nd') or len(note.findall('dot'))>2:raise ValueError('unsupported_written_note_value')
            notation=note.find('notations')
            if notation is not None:
                for el in list(notation):
                    if el.tag not in ('tied','tuplet'):notation.remove(el)
                    elif el.tag=='tuplet':
                        for child in list(el):el.remove(child)
            for beam in note.findall('beam'):
                if beam.get('number','1') not in ('1','2','3') or beam.text not in ('begin','continue','end','forward hook','backward hook'):raise ValueError('unsupported_beaming')
    data=ET.tostring(normalized,encoding='utf8',xml_declaration=True)
    # Mode unknown -> none is an explicit unspecified label, not a tonal guess.
    before=decode(raw,'before',{})[2];after=decode(data,'after',{})[2]
    assert [(a['midi'],a['absolute_onset_qn'],a['sounding_duration_qn']) for a in before]==[(a['midi'],a['absolute_onset_qn'],a['sounding_duration_qn']) for a in after]
    return normalized,(n,d),fifths,mode

def inventory_workspace():
    records=[]
    for row in current_existing():
        q=row['metadata'];records.append((dict(source='existing',source_id=q['id'],question_id=q['id'],existing=row),read_xml(CONTENT/row['main_path'])))
    library=WORKSPACE/'ear_training_8bars_1047_XML_only/ear_training_8bars_1047'
    for item in csv.DictReader((library/'problem_list.csv').open(encoding='utf-8-sig',newline='')):
        original=(library/item['xml_path']).read_bytes();assert sha(original)==item['sha256_xml']
        raw=original;repair=None
        repaired=WORKSPACE/'output/difficulty-separation/normalized_inputs'/(item['id']+'.musicxml')
        if repaired.exists():raw=repaired.read_bytes();repair='Previously audited notation precision/measure-rest flag correction; original bytes retained.'
        records.append((dict(source='trained-ear',source_id=item['id'],original_sha256=sha(original),original_xml_path=item['xml_path'],
            source_url=item['source_url'],license='CC BY-SA 4.0',notation_repair=repair),raw))
    for count in (100,1000):
        archive=WORKSPACE/f'generated_{count}_by_level.zip'
        archive_hash=sha(archive.read_bytes())
        with zipfile.ZipFile(archive) as z:
            prefix=f'generated_{count}_by_level/'
            for item in csv.DictReader(io.StringIO(z.read(prefix+'problem_list.csv').decode('utf-8-sig'))):
                raw=z.read(prefix+item['xml_path']);assert sha(raw)==item['sha256_xml']
                records.append((dict(source=f'generated-{count}',source_id=item['id'],original_sha256=sha(raw),archive_sha256=archive_hash),raw))
    return records

def prepare(from_workspace=False):
    SOURCE.mkdir(parents=True,exist_ok=True);WORK.mkdir(parents=True,exist_ok=True)
    if from_workspace:
        records=inventory_workspace()
        with zipfile.ZipFile(SOURCE/'sources.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
            meta=[]
            for item,raw in records:
                name=f'{item["source"]}/{item["source_id"]}.musicxml';info=zipfile.ZipInfo(name,(2026,11,11,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;z.writestr(info,raw)
                if item.get('notation_repair'):
                    item['original_archive_path']='originals/'+name
                    original=(WORKSPACE/'ear_training_8bars_1047_XML_only/ear_training_8bars_1047'/item['original_xml_path']).read_bytes()
                    assert sha(original)==item['original_sha256']
                    original_info=zipfile.ZipInfo(item['original_archive_path'],(2026,11,11,0,0,0));original_info.compress_type=zipfile.ZIP_DEFLATED;z.writestr(original_info,original)
                meta.append(dict(**item,archive_path=name,sha256=sha(raw)))
        license_path=WORKSPACE/'ear_training_8bars_1047_XML_only/ear_training_8bars_1047/SOURCES_AND_LICENSE.md'
        if license_path.exists():shutil.copyfile(license_path,SOURCE/'TRAINED-EAR-LICENSE.md')
        write_json(SOURCE/'inventory.json',meta)
    else:
        meta=read_json(SOURCE/'inventory.json')
        with zipfile.ZipFile(SOURCE/'sources.zip') as z:records=[(item,z.read(item['archive_path'])) for item in meta]
    accepted=[];all_scores=[];excluded=[];duplicates=[];seen={};new_count=0;sheet_combinations=set()
    for i,(source,raw) in enumerate(records):
        original=dict(source=source['source'],source_id=source['source_id'],source_sha256=sha(raw))
        try:
            mm,_,_,_=decode(raw,'input',{});meter=dict(zip(('numerator','denominator'),map(int,mm[0]['meter'].split('/'))))
            tempo=resolve_tempo(meter);bpm=quarter_bpm(tempo)
            result=analyze(raw,quarter_bpm=bpm,reference_quarter_bpm=bpm)
            all_scores.append(dict(**original,analysis=result))
            root,mt,fifths,mode=app_normalize(raw)
            canonical=ET.tostring(root,encoding='utf8',xml_declaration=True);family=identity(canonical)
            if family in seen:
                duplicates.append(dict(**original,canonical_question_id=seen[family]));continue
            existing=source.get('existing');new_count+=not bool(existing)
            qid=source.get('question_id') or str(uuid.uuid5(uuid.NAMESPACE_URL,'https://sori.local/practice-bank/'+source['source']+'/'+source['source_id']))
            seen[family]=qid
            normalized_score=analyze(canonical,quarter_bpm=bpm,reference_quarter_bpm=bpm)
            assert math.isclose(result['score'],normalized_score['score'],rel_tol=0,abs_tol=1e-9),'Normalization changed difficulty'
            if existing:
                item=copy.deepcopy(existing);asset_sha=item['metadata']['score_assets']['main']['sha256']
            else:
                folder=f'questions/bank-{qid}/v1';target=CONTENT/folder;target.mkdir(parents=True,exist_ok=True)
                title=f'청음 문제 {new_count:04}'
                root.find('work/work-title').text=title
                main=build.package(root);sc,count=scale(mt,fifths,mode);assets={}
                for kind,data,bars in [('main',main,8),('scale',sc,count)]:
                    (target/(kind+'.mxl')).write_bytes(data);(RESOURCES/f'practice-{qid}-{kind}.mxl').write_bytes(data)
                    assets[kind]=dict(url=f'https://api.sori.example/api/v1/questions/{qid}/versions/1/scores/{kind}/',
                        content_type='application/vnd.recordare.musicxml',sha256=sha(data),size_bytes=len(data),musicxml_version='4.0',
                        profile='sori-monophonic-v4',part_id='P1',measure_count=bars,source_tempo_bpm=96)
                key=dict(tonic=(MINOR if mode=='minor' else MAJOR)[fifths+7],mode='unspecified' if mode=='none' else mode,fifths=fifths)
                q=dict(id=qid,version=1,title=title,source='practice',collection='practice_bank',
                    difficulty='beginner' if result['level']<=3 else 'intermediate' if result['level']<=6 else 'advanced',
                    practice_level=result['level'],difficulty_score=result['score'],difficulty_version=VERSION,
                    key_signature=key,time_signature=meter,measure_count=8,recommended_duration_seconds=300,
                    description='선율을 듣고 8마디를 적어보세요.',time_policy='advisory',clef='treble',sheet_layout={},
                    content_policy='client_readable_practice',score_visibility='after_submission',score_assets=assets)
                item=dict(order=3000+new_count,metadata=q,main_path=folder+'/main.mxl',scale_path=folder+'/scale.mxl')
                asset_sha=assets['main']['sha256']
            display=prepare_display(copy.deepcopy(root));name='bank-'+qid
            path=WORK/(name+'.musicxml');path.write_bytes(ET.tostring(display,encoding='utf8',xml_declaration=True))
            accepted.append(dict(**original,question_id=qid,existing=bool(existing),item=item,analysis=result,
                main_sha256=asset_sha,identity=family,render_input=str(path),resource=name+'-reference-v1',meter=list(mt),fifths=fifths))
            sheet_combinations.add((mt[0],mt[1],fifths))
        except (ValueError,AssertionError,ET.ParseError,KeyError,TypeError,ZeroDivisionError) as err:
            excluded.append(dict(**original,reason=str(err),scored=any(r['source']==source['source'] and r['source_id']==source['source_id'] for r in all_scores)))
        if (i+1)%100==0:print('Processed',i+1,'/',len(records),flush=True)
    write_json(WORK/'accepted.json',accepted);write_json(SOURCE/'scores.json',all_scores)
    write_json(SOURCE/'import-audit.json',dict(total=len(records),scored=len(all_scores),accepted=len(accepted),
        excluded=excluded,duplicates=duplicates,score_version=VERSION,cutoffs=CUTOFFS,
        counts=dict(collections.Counter(r['analysis']['level'] for r in accepted)),
        sources=dict(collections.Counter(r['source'] for r in accepted))))
    write_json(SOURCE/'sheets.json',[list(x) for x in sorted(sheet_combinations)])
    print(json.dumps(read_json(SOURCE/'import-audit.json'),ensure_ascii=False)[:4000],flush=True)

def render(limit=0,batch_size=20):
    version=subprocess.run(['C:/Program Files/MuseScore 4/bin/MuseScore4.exe','--long-version'],capture_output=True,
        text=True,timeout=30,check=True,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    if '4.6.3' not in version.stdout+version.stderr:raise ValueError('Pinned renderer must be MuseScore Studio 4.6.3')
    rows=read_json(WORK/'accepted.json');old=read_json(CONTENT/'engraving/manifest.json')['scores']
    jobs=[]
    for r in rows:
        if r['main_sha256'] in old:continue
        output=WORK/(r['resource']+'-1.png')
        if output.exists():continue
        jobs.append({'in':r['render_input'],'out':[str(WORK/(r['resource']+'.png')),str(WORK/(r['resource']+'.svg'))]})
    if limit:jobs=jobs[:limit]
    for i in range(0,len(jobs),batch_size):
        jf=WORK/'render-jobs.json';write_json(jf,jobs[i:i+batch_size])
        with (WORK/f'render-{i:04}.log').open('wb') as log:
            p=subprocess.run(['C:/Program Files/MuseScore 4/bin/MuseScore4.exe','-T','12','-r','240',
                '-S',str(ROOT/'scripts/engraving/compact-v1.mss'),'-j',str(jf)],stdout=log,stderr=log,
                timeout=180,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if p.returncode:raise RuntimeError('MuseScore failed: '+str(WORK/f'render-{i:04}.log'))
        print('Rendered',min(i+batch_size,len(jobs)),'/',len(jobs),flush=True)
    # Explicit bar-five breaks do not prevent MuseScore from wrapping an earlier
    # dense measure. A wider/smaller-staff fallback preserves exactly 4+4 bars.
    def needs_wide(r):
        svg=WORK/(r['resource']+'-1.svg')
        return (WORK/(r['resource']+'-2.png')).exists() or (svg.exists() and svg.read_text(encoding='utf8').count('class="StaffLines"')!=10)
    tall=[{'in':r['render_input'],'out':[str(WORK/(r['resource']+'-four-bars.png')),str(WORK/(r['resource']+'-four-bars.svg'))]} for r in rows
          if needs_wide(r) and not (WORK/(r['resource']+'-four-bars-1.png')).exists()]
    for i in range(0,len(tall),batch_size):
        jf=WORK/'tall-jobs.json';write_json(jf,tall[i:i+batch_size])
        with (WORK/f'tall-{i:04}.log').open('wb') as log:
            p=subprocess.run(['C:/Program Files/MuseScore 4/bin/MuseScore4.exe','-T','12','-r','240',
                '-S',str(ROOT/'scripts/engraving/bank-four-bars-v1.mss'),'-j',str(jf)],stdout=log,stderr=log,
                timeout=180,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if p.returncode:raise RuntimeError('Tall score engraving failed')
        print('Reflowed 4+4 scores',min(i+batch_size,len(tall)),'/',len(tall),flush=True)

def publish(allow_unpublished_preview_fix=False):
    rows=read_json(WORK/'accepted.json');manifest=read_json(CONTENT/'engraving/manifest.json')
    current=copy.deepcopy(manifest);catalog=[];score_map={}
    for r in rows:
        item=r['item'];q=item['metadata'];qid=r['question_id'];a=r['analysis']
        if not r['existing']:
            n,d=r['meter'];layout_id=f'staff-8bars-{n}-{d}-key{r["fifths"]}-v4'
            layout=read_json(CONTENT/'sheets'/(layout_id+'.layout.json')) if (CONTENT/'sheets'/(layout_id+'.layout.json')).exists() else copy.deepcopy(read_json(CONTENT/'sheet-revisions.json')[0]['metadata']['sheet_layout'])
            png=(CONTENT/'sheets'/(layout_id+'.png')).read_bytes()
            layout.update(id=layout_id,template_png_url=f'https://api.sori.example/assets/sheets/{layout_id}.png',template_sha256=sha(png))
            q['sheet_layout']=layout;write_json(CONTENT/'sheets'/(layout_id+'.layout.json'),layout)
            (RESOURCES/(layout_id+'.pngdata')).write_bytes(png)
            q.update(timed_question(q));catalog.append(item)
        old_image=manifest['scores'].get(r['main_sha256'])
        if old_image is None or (allow_unpublished_preview_fix and not r['existing']):
            wide=(WORK/(r['resource']+'-four-bars-1.png')).exists()
            prefix=r['resource']+('-four-bars' if wide else '')
            image=WORK/(prefix+'-1.png');data=image.read_bytes();width,height=struct.unpack('>II',data[16:24])
            if (WORK/(prefix+'-2.png')).exists():raise ValueError('Reference must fit one page: '+qid)
            svg=WORK/(prefix+'-1.svg')
            if svg.exists() and svg.read_text(encoding='utf8').count('class="StaffLines"')!=10:raise ValueError('Reference must have exactly two systems: '+qid)
            if old_image and sha(data)!=old_image['sha256'] and not (allow_unpublished_preview_fix and q.get('collection')=='practice_bank'):
                raise ValueError('Published preview is immutable: '+qid)
            if not (1600<=width<=3000 and 150<=height<=850):raise ValueError(f'Unexpected reference image {qid}: {width}x{height}')
            (CONTENT/'engraving'/(r['resource']+'.png')).write_bytes(data);(RESOURCES/(r['resource']+'.pngdata')).write_bytes(data)
            manifest['scores'][r['main_sha256']]=dict(resource=r['resource'],content_type='image/png',sha256=sha(data),size_bytes=len(data),pixel_width=width,pixel_height=height,renderer=manifest['renderer'])
            if wide:
                manifest['scores'][r['main_sha256']].update(style='bank-four-bars-v1',style_sha256=sha((ROOT/'scripts/engraving/bank-four-bars-v1.mss').read_bytes()))
        score_map[qid]=dict(main_sha256=r['main_sha256'],score=a['score'],content_score=a['content_score'],
            key_correction=a['key_correction'],quarter_bpm=a['quarter_bpm'],reference_quarter_bpm=a['reference_quarter_bpm'],
            level=a['level'],source=r['source'],source_id=r['source_id'])
    assert all(manifest['scores'][k]==v for k,v in current['scores'].items()
               if not (allow_unpublished_preview_fix and v['resource'].startswith('bank-')))
    scores=dict(version=VERSION,cutoffs=list(CUTOFFS),records=score_map,
        calibration={'level_1':'Hobbyist entry','level_5':'Reviewed intermediate exercises','level_9':'Reviewed advanced exercises'},
        formula={'key':'min(8, fifths^2/6) * (0.5 + 0.5 * used_signature_letters/fifths)',
                 'tempo':'(content + key) * actual_quarter_bpm/reference_quarter_bpm'})
    write_json(CONTENT/'practice-bank-catalog.json',catalog)
    write_json(RESOURCES/'practice-bank-catalog.json',[r['metadata'] for r in catalog])
    write_json(CONTENT/'practice-difficulty.json',scores);write_json(RESOURCES/'practice-difficulty.json',scores)
    write_json(CONTENT/'engraving/manifest.json',manifest);write_json(RESOURCES/'engraving-manifest.json',manifest)
    print('Published',len(score_map),'unique practice questions; new assets:',len(catalog),flush=True)

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('stage',choices=['prepare','render','publish'])
    ap.add_argument('--from-workspace',action='store_true');ap.add_argument('--limit',type=int,default=0)
    ap.add_argument('--unpublished-preview-fix',action='store_true',help='One-time QA repair before publishing this new bank; never use on deployed assets')
    a=ap.parse_args()
    if a.stage=='prepare':prepare(a.from_workspace)
    elif a.stage=='render':render(a.limit)
    else:publish(a.unpublished_preview_fix)
