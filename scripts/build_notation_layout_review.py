"""Compare real shipped exercises before adopting a common MuseScore sheet layout.

Never edits published scores, styles, catalogs or submitted answers. Outputs go to
the workspace's output directory. MuseScore is only needed at authoring time.
"""
import argparse
import collections
import copy
from fractions import Fraction
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import shutil
import xml.etree.ElementTree as ET
import zipfile
import engraving_geometry as geometry

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
DEFAULT_OUT=ROOT.parent/'output/practice-notation-review'
STYLE=ROOT/'scripts/engraving/practice-review-v1.mss'
CATALOGS=('catalog.json','classical-catalog.json','additional-practice-catalog.json','sheet-revisions.json',
          'brahms-catalog.json','classical-tempo-revisions.json','mahler-catalog.json',
          'practice-bank-catalog.json','sheet-revisions-v5.json')
EXE='C:/Program Files/MuseScore 4/bin/MuseScore4.exe'

def write_json(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

def read_xml(path):
    if path.suffix.lower() in ('.mxl','.mscz'):
        with zipfile.ZipFile(path) as z:
            container=ET.fromstring(z.read('META-INF/container.xml'))
            name=next(n.get('full-path') for n in container.iter() if n.tag.rsplit('}',1)[-1]=='rootfile')
            return ET.fromstring(z.read(name))
    return ET.parse(path).getroot()

def latest_questions():
    latest={}
    for filename in CATALOGS:
        for item in json.loads((CONTENT/filename).read_text(encoding='utf-8')):
            q=item['metadata']
            if q['id'] not in latest or q['version']>latest[q['id']]['metadata']['version']:
                latest[q['id']]=item
    return list(latest.values())

def metrics(root):
    notes=root.findall('./part/measure/note')
    count=collections.Counter(n.findtext('type','unknown') for n in notes)
    per=[len(m.findall('note')) for m in root.findall('./part/measure')]
    return dict(notes=len(notes),max_notes=max(per),tuplets=sum(n.find('time-modification') is not None for n in notes),
                accidental_notes=sum(n.find('accidental') is not None or n.findtext('pitch/alter','0')!='0' for n in notes),
                ties=sum(t.get('type')=='start' for n in notes for t in n.findall('tie')),
                rests=sum(n.find('rest') is not None for n in notes),sixteenths=count['16th'],
                types=dict(count))

def music_signature(root):
    result=[];divisions=1
    for measure in root.findall('./part/measure'):
        if measure.findtext('attributes/divisions'):divisions=int(measure.findtext('attributes/divisions'))
        result.append([(n.find('rest') is not None,n.findtext('pitch/step'),n.findtext('pitch/alter','0'),n.findtext('pitch/octave'),
                        str(Fraction(n.findtext('duration','0'))/divisions),
                        sorted(t.get('type') for t in n.findall('tie'))) for n in measure.findall('note')])
    return result

def choose_samples(out):
    difficulty=json.loads((CONTENT/'practice-difficulty.json').read_text(encoding='utf-8'))['records']
    rows=[]
    for item in latest_questions():
        q=item['metadata'];root=read_xml(CONTENT/item['main_path'])
        if len(root.findall('./part/measure'))!=8:continue
        score=difficulty.get(q['id'],{})
        rows.append(dict(item=item,metrics=metrics(root),level=score.get('level'),score=score.get('score')))
    selected=[];used=set()
    def pick(reason,condition,ranking=lambda r:r['metrics']['notes']):
        available=[r for r in rows if r['item']['metadata']['id'] not in used and condition(r)]
        if not available:return
        r=max(available,key=ranking);used.add(r['item']['metadata']['id'])
        selected.append(dict(r,reason=reason))
    q=lambda r:r['item']['metadata'];mt=lambda r:(q(r)['time_signature']['numerator'],q(r)['time_signature']['denominator'])
    pick('초급 · 성긴 선율',lambda r:r['level']==1 and q(r)['key_signature']['fifths']==0,lambda r:-abs(r['metrics']['notes']-24))
    pick('초급 · 단조와 조표',lambda r:r['level'] in (2,3) and q(r)['key_signature']['mode']=='minor',lambda r:abs(q(r)['key_signature']['fifths']))
    pick('기존 중급 · 6/8',lambda r:r['item']['order']<=3 and mt(r)==(6,8))
    pick('기존 중급 · 4/4',lambda r:r['item']['order']<=3 and mt(r)==(4,4))
    pick('기존 중급 · 3/4',lambda r:r['item']['order']<=3 and mt(r)==(3,4))
    pick('중간 난이도 · 16분음표',lambda r:r['level'] in (4,5,6),lambda r:r['metrics']['sixteenths'])
    pick('고급 · 음표가 밀집한 마디',lambda r:r['level']==9,lambda r:r['metrics']['max_notes'])
    pick('고급 · 임시표 밀집',lambda r:r['level'] in (8,9),lambda r:r['metrics']['accidental_notes'])
    pick('셋잇단음표가 많은 문제',lambda r:q(r).get('collection')!='classical',lambda r:r['metrics']['tuplets'])
    pick('붙임줄이 많은 문제',lambda r:q(r).get('collection')!='classical',lambda r:r['metrics']['ties'])
    pick('조표가 많은 문제',lambda r:r['level'] is not None,lambda r:(abs(q(r)['key_signature']['fifths']),r['metrics']['notes']))
    pick('12/8 박자',lambda r:mt(r)==(12,8))
    pick('홀수 박자',lambda r:mt(r) in ((5,4),(7,8),(5,8)))
    pick('2분음표 기준 박자',lambda r:mt(r)[1]==2 and q(r).get('collection')!='classical')
    pick('클래식 · 브람스',lambda r:'brahms' in r['item']['main_path'].lower(),lambda r:r['metrics']['max_notes'])
    pick('클래식 · 말러',lambda r:'mahler' in r['item']['main_path'].lower(),lambda r:r['metrics']['notes'])
    out.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('review_score_prepare',ROOT/'scripts/build_score_previews.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    result=[];jobs=[]
    for number,r in enumerate(selected,1):
        item=r['item'];q=item['metadata'];root=read_xml(CONTENT/item['main_path']);before=music_signature(root)
        root=module.prepare(root)
        for m in root.findall('./part/measure'):
            for p in list(m.findall('print')):m.remove(p)
        root.findall('./part/measure')[4].insert(0,ET.Element('print',{'new-system':'yes'}))
        assert music_signature(root)==before
        name=f'{number:02d}'
        folder=out/name;folder.mkdir(exist_ok=True)
        ET.ElementTree(root).write(folder/'source.musicxml',encoding='utf-8',xml_declaration=True)
        result.append(dict(number=number,reason=r['reason'],id=q['id'],version=q['version'],title=q['title'],
                           key=q['key_signature'],meter=q['time_signature'],level=r['level'],score=r['score'],metrics=r['metrics'],
                           source=item['main_path'],asset_sha256=q['score_assets']['main']['sha256'],layout=q['sheet_layout']))
        jobs.append({'in':str(folder/'source.musicxml'),'out':[str(folder/'natural.mscx'),str(folder/'natural.svg'),str(folder/'natural.png')]})
    write_json(out/'samples.json',result)
    write_json(out/'import-jobs.json',jobs)
    write_json(out/'source-audit.json',{'registered_questions':len(rows),'sample_count':len(result),'ids':[r['id'] for r in result],
                                     'selection':'Diverse real registered eight-bar questions; no generated test exercises.',
                                     'renderer':'MuseScore Studio 4.6.3','style_sha256':hashlib.sha256(STYLE.read_bytes()).hexdigest()})
    print(json.dumps({'samples':len(result),'reasons':[r['reason'] for r in result]},ensure_ascii=False),flush=True)

def render_jobs(out,jobs,musescore,style=None):
    flags={'creationflags':getattr(subprocess,'CREATE_NO_WINDOW',0)} if os.name=='nt' else {}
    version=subprocess.run([musescore,'--long-version'],capture_output=True,text=True,timeout=30,**flags)
    if '4.6.3' not in version.stdout+version.stderr:raise RuntimeError('Expected pinned MuseScore Studio 4.6.3: '+version.stdout+version.stderr)
    command=[musescore,'-T','12','-r','180']
    if style:command+=['-S',str(style)]
    command+=['-j',str(jobs)]
    with (out/(jobs.stem+'.log')).open('wb') as log:
        proc=subprocess.run(command,stdout=log,stderr=log,timeout=240,**flags)
    if proc.returncode:raise RuntimeError('MuseScore export failed: '+str(jobs))
    print('Rendered '+jobs.name,flush=True)

def probe(out,musescore):
    jobs=[]
    for tag in ['stretch','userStretch']:
        path=out/'01'/f'probe-{tag}.mscx'
        tree=ET.parse(out/'01/natural.mscx')
        ET.SubElement(tree.find('./Score/Staff/Measure'),tag).text='2'
        tree.write(path,encoding='utf-8',xml_declaration=True)
        jobs.append({'in':str(path),'out':[str(path.with_suffix('.svg')),str(path.with_name(path.stem+'-result.mscx'))]})
    write_json(out/'probe-jobs.json',jobs)
    render_jobs(out,out/'probe-jobs.json',musescore)
    blanks=out/'blanks';blanks.mkdir(exist_ok=True)
    combos={(r['meter']['numerator'],r['meter']['denominator'],r['key']['fifths']) for r in json.loads((out/'samples.json').read_text(encoding='utf-8'))}
    jobs=[]
    for beats,unit,fifths in sorted(combos):
        score=ET.Element('score-partwise',{'version':'4.0'})
        partlist=ET.SubElement(score,'part-list');sp=ET.SubElement(partlist,'score-part',{'id':'P1'});ET.SubElement(sp,'part-name').text=''
        part=ET.SubElement(score,'part',{'id':'P1'})
        for i in range(1,9):
            measure=ET.SubElement(part,'measure',{'number':str(i)})
            if i==5:ET.SubElement(measure,'print',{'new-system':'yes'})
            if i==1:
                attrs=ET.SubElement(measure,'attributes');ET.SubElement(attrs,'divisions').text='480'
                key=ET.SubElement(attrs,'key');ET.SubElement(key,'fifths').text=str(fifths)
                time=ET.SubElement(attrs,'time');ET.SubElement(time,'beats').text=str(beats);ET.SubElement(time,'beat-type').text=str(unit)
                clef=ET.SubElement(attrs,'clef');ET.SubElement(clef,'sign').text='G';ET.SubElement(clef,'line').text='2'
            note=ET.SubElement(measure,'note',{'print-object':'no','print-spacing':'yes'})
            ET.SubElement(note,'rest',{'measure':'yes'});ET.SubElement(note,'duration').text=str(beats*480*4//unit)
        source=blanks/f'{beats}-{unit}-key{fifths}.musicxml';ET.ElementTree(score).write(source,encoding='utf-8',xml_declaration=True)
        jobs.append({'in':str(source),'out':[str(source.with_suffix('.svg')),str(source.with_suffix('.mscx'))]})
    write_json(out/'blank-jobs.json',jobs)
    render_jobs(out,out/'blank-jobs.json',musescore,STYLE)

def svg_geometry(path):
    root=ET.parse(path).getroot()
    nodes=[n for n in root if n.get('class')=='StaffLines']
    lines=[]
    for n in nodes:
        values=[float(v) for v in re.findall(r'-?\d+(?:\.\d+)?',n.get('points',''))]
        lines.append((values[0],values[1],values[2]))
    lines.sort(key=lambda v:v[1])
    systems=[]
    for i in range(0,len(lines),5):
        staff=lines[i:i+5]
        if len(staff)!=5:raise ValueError('Incomplete staff')
        y=staff[0][1];space=staff[1][1]-y
        bars=[]
        for n in root:
            if n.get('class')!='BarLine':continue
            values=[float(v) for v in re.findall(r'-?\d+(?:\.\d+)?',n.get('points',''))]
            if len(values)==4 and abs(values[1]-y)<space:
                bars.append(values[0])
        # Thick final bars may contain a second closely spaced line.
        ordered=[]
        for x in sorted(bars):
            if not ordered or x-ordered[-1]>space*.5:ordered.append(x)
        systems.append(dict(left=staff[0][0],right=staff[0][2],top=y,space=space,bars=ordered))
    return systems

def constrain(out,musescore):
    rows=json.loads((out/'samples.json').read_text(encoding='utf-8'))
    jobs=[]
    for r in rows:
        folder=out/f'{r["number"]:02d}';tree=ET.parse(folder/'natural.mscx');score=tree.find('Score')
        for n in list(score.findall('SystemLocks')):score.remove(n)
        measures=score.findall('./Staff/Measure')
        if len(measures)!=8:raise ValueError('Native score must have eight bars')
        before=[ET.tostring(m.find('voice')) for m in measures]
        for m in measures:
            for n in list(m.findall('LayoutBreak')):m.remove(n)
        locks=ET.SubElement(score,'SystemLocks')
        for start,end in [(0,3),(4,7)]:
            lock=ET.SubElement(locks,'systemLock')
            ET.SubElement(lock,'startMeasure').text=measures[start].findtext('eid')
            ET.SubElement(lock,'endMeasure').text=measures[end].findtext('eid')
        assert before==[ET.tostring(m.find('voice')) for m in measures]
        tree.write(folder/'locked.mscx',encoding='utf-8',xml_declaration=True)
        jobs.append({'in':str(folder/'locked.mscx'),'out':[str(folder/'locked.svg'),str(folder/'locked.png')]})
    write_json(out/'locked-jobs.json',jobs);render_jobs(out,out/'locked-jobs.json',musescore)
    for r in rows:
        b,u,f=r['meter']['numerator'],r['meter']['denominator'],r['key']['fifths']
        path=out/'blanks'/f'{b}-{u}-key{f}-1.svg'
        blank,layout=geometry.canonical_blank(path,b,u,f)
        ET.ElementTree(blank).write(path.with_name(f'{b}-{u}-key{f}-canonical.svg'),encoding='utf-8',xml_declaration=True)
        write_json(path.with_name(f'{b}-{u}-key{f}-canonical.layout.json'),layout)
    for r in rows:
        folder=out/f'{r["number"]:02d}'
        svg,metrics=geometry.canonical_reference(folder/'locked-1.svg')
        ET.ElementTree(svg).write(folder/'natural-canonical.svg',encoding='utf-8',xml_declaration=True)
        write_json(folder/'natural-metrics.json',metrics)
    print('Locked 16 real scores to 4+4 bars and composed the shared MuseScore blank glyphs.',flush=True)

def uniform(out,musescore):
    rows=json.loads((out/'samples.json').read_text(encoding='utf-8'))
    stretches={r['number']:[1.]*8 for r in rows};pending=rows[:];history=[]
    for iteration in range(1,10):
        jobs=[]
        for r in pending:
            folder=out/f'{r["number"]:02d}';tree=ET.parse(folder/'locked.mscx')
            for m,value in zip(tree.findall('./Score/Staff/Measure'),stretches[r['number']]):
                n=m.find('stretch')
                if n is None:n=ET.SubElement(m,'stretch')
                n.text=f'{value:.8f}'
            source=folder/'equal.mscx';tree.write(source,encoding='utf-8',xml_declaration=True)
            jobs.append({'in':str(source),'out':[str(folder/'equal.svg'),str(folder/'equal.png')]})
        write_json(out/'equal-jobs.json',jobs);render_jobs(out,out/'equal-jobs.json',musescore)
        next_pending=[]
        for r in pending:
            folder=out/f'{r["number"]:02d}';svg,metrics=geometry.canonical_reference(folder/'equal-1.svg')
            b,u,f=r['meter']['numerator'],r['meter']['denominator'],r['key']['fifths']
            layout=json.loads((out/'blanks'/f'{b}-{u}-key{f}-canonical.layout.json').read_text(encoding='utf-8'))
            target=layout['systems'][0]['barline_x'];error=max(abs(a-t) for row in metrics['barlines'] for a,t in zip(row,target))
            metrics.update(max_barline_error=error,iterations=iteration,stretch=stretches[r['number']][:],aligned=error<1.)
            ET.ElementTree(svg).write(folder/'equal-canonical.svg',encoding='utf-8',xml_declaration=True)
            write_json(folder/'equal-metrics.json',metrics)
            if error>=1:
                for row_index,actual in enumerate(metrics['barlines']):
                    for i in range(4):
                        ratio=(target[i+1]-target[i])/(actual[i+1]-actual[i])
                        k=row_index*4+i
                        stretches[r['number']][k]=min(50,max(.025,stretches[r['number']][k]*ratio))
                next_pending.append(r)
        history.append(dict(iteration=iteration,remaining=[r['number'] for r in next_pending]))
        print(json.dumps(history[-1]),flush=True)
        pending=next_pending
        if not pending:break
    write_json(out/'equal-convergence.json',history)

def publish_review(out):
    """Publish an authoring review, never an immutable question/catalog revision."""
    rows=json.loads((out/'samples.json').read_text(encoding='utf-8'))
    manifest=json.loads((CONTENT/'engraving/manifest.json').read_text(encoding='utf-8'))
    cases=[]
    for r in rows:
        folder=out/f'{r["number"]:02d}';b,u,f=r['meter']['numerator'],r['meter']['denominator'],r['key']['fifths']
        blank,layout=geometry.canonical_blank(out/'blanks'/f'{b}-{u}-key{f}-1.svg',b,u,f)
        blank_path=out/'blanks'/f'{b}-{u}-key{f}-canonical.svg'
        ET.ElementTree(blank).write(blank_path,encoding='utf-8',xml_declaration=True)
        write_json(blank_path.with_suffix('.layout.json'),layout)
        current=manifest['scores'][r['asset_sha256']]
        shutil.copyfile(CONTENT/'engraving'/(current['resource']+'.png'),folder/'current.png')
        shutil.copyfile(CONTENT/'sheets'/(r['layout']['id']+'.svg'),folder/'current-blank.svg')
        blank_display=copy.deepcopy(blank);blank_display.set('viewBox','0 80 1330 480');blank_display.set('width','1330');blank_display.set('height','480')
        ET.ElementTree(blank_display).write(folder/'blank-display.svg',encoding='utf-8',xml_declaration=True)
        guide=ET.Element('{'+geometry.NS+'}svg',{'viewBox':'0 80 1330 480','width':'1330','height':'480'})
        for s in layout['systems']:
            for x in s['barline_x'][1:-1]:
                ET.SubElement(guide,'path',{'d':f'M{x} {s["staff_line_y"][0]-60}v168','stroke':'#7b61c2','stroke-width':'1.6','stroke-dasharray':'5 5','opacity':'.6','fill':'none'})
        ET.ElementTree(guide).write(folder/'guide.svg',encoding='utf-8',xml_declaration=True)
        summaries={}
        for variant,source in [('natural','locked-1.svg'),('equal','equal-1.svg')]:
            svg,metrics=geometry.canonical_reference(folder/source)
            target=layout['systems'][0]['barline_x']
            metrics['max_barline_error']=max(abs(a-t) for row in metrics['barlines'] for a,t in zip(row,target))
            metrics['aligned']=metrics['max_barline_error']<2
            metrics['crowding_indicator']=metrics['minimum_notehead_centres_sp'] is not None and metrics['minimum_notehead_centres_sp']<1.6
            write_json(folder/(variant+'-metrics.json'),metrics)
            ET.ElementTree(svg).write(folder/(variant+'-canonical.svg'),encoding='utf-8',xml_declaration=True)
            svg.set('viewBox','0 80 1330 480');svg.set('height','480')
            ET.ElementTree(svg).write(folder/(variant+'-display.svg'),encoding='utf-8',xml_declaration=True)
            summaries[variant]=metrics
        # A large, common-scale symbol comparison makes the actual font change visible.
        for label,tree in [('old',ET.parse(folder/'current-blank.svg').getroot()),('new',copy.deepcopy(blank)),('reference',ET.parse(folder/'natural-canonical.svg').getroot())]:
            tree.set('viewBox','50 112 310 140');tree.set('width','620');tree.set('height','280')
            ET.ElementTree(tree).write(folder/(label+'-symbols.svg'),encoding='utf-8',xml_declaration=True)
        cases.append(dict(r,results=summaries,folder=f'{r["number"]:02d}'))
    report=dict(cases=cases,sample_count=len(cases),new_blank_combinations=len({(c['meter']['numerator'],c['meter']['denominator'],c['key']['fifths']) for c in cases}),
                equal_aligned=sum(c['results']['equal']['aligned'] for c in cases),
                natural_crowding=sum(c['results']['natural']['crowding_indicator'] for c in cases),
                equal_crowding=sum(c['results']['equal']['crowding_indicator'] for c in cases),
                published_assets_modified=False,answer_images_modified=False,
                policy='Review before publication: shared Leland symbols and staff positions are independent of answer density; equal-width attempts use native MuseScore stretch and 4+4 system locks.',
                alignment_tolerance_logical_units=2,
                sources=['https://handbook.musescore.org/formatting/systems-and-horizontal-spacing',
                         'https://github.com/musescore/MuseScore/blob/v4.6.3/src/engraving/rw/write/twrite.cpp'])
    write_json(out/'report.json',report)
    template=ROOT/'scripts/engraving/notation-review.html'
    (out/'index.html').write_text(template.read_text(encoding='utf-8').replace('/* REVIEW_DATA */',json.dumps(report,ensure_ascii=False)),encoding='utf-8')
    with zipfile.ZipFile(out/'practice-notation-review.zip','w',zipfile.ZIP_DEFLATED) as archive:
        for name in ['index.html','report.json','samples.json','source-audit.json']:
            archive.write(out/name,name)
        for c in cases:
            for name in ['current.png','natural-display.svg','equal-display.svg','blank-display.svg','guide.svg','old-symbols.svg','new-symbols.svg','reference-symbols.svg']:
                path=out/c['folder']/name;archive.write(path,str(path.relative_to(out)))
    print(json.dumps({k:v for k,v in report.items() if k!='cases'},ensure_ascii=False),flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=['prepare','import','probe','inspect','constrain','uniform','review'])
    parser.add_argument('--output',type=Path,default=DEFAULT_OUT)
    parser.add_argument('--musescore',default=EXE)
    args=parser.parse_args();out=args.output.resolve()
    if args.phase=='prepare':choose_samples(out)
    elif args.phase=='import':render_jobs(out,out/'import-jobs.json',args.musescore,STYLE)
    elif args.phase=='probe':probe(out,args.musescore)
    elif args.phase=='constrain':constrain(out,args.musescore)
    elif args.phase=='uniform':uniform(out,args.musescore)
    elif args.phase=='review':publish_review(out)
    elif args.phase=='inspect':
        values={r['number']:svg_geometry(out/f'{r["number"]:02d}/natural-1.svg') for r in json.loads((out/'samples.json').read_text(encoding='utf-8'))}
        write_json(out/'natural-geometry.json',values)
        print(json.dumps({k:{'systems':len(v),'measures':[len(s['bars']) for s in v],'space':v[0]['space'],'width':v[0]['right']-v[0]['left']} for k,v in values.items()}))

if __name__=='__main__':main()
