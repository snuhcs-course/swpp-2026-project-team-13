"""Publish v6 MuseScore sheets and 4+4 reference geometry without changing old assets.

Native MuseScore layout stretch is tried first. A reference uses that equal grid
only if it converges and retains readable notehead spacing; otherwise its natural
measure widths are retained. Blank sheets never depend on the answer's density.
All caches are resumable; previously published question versions stay untouched.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile

import engraving_geometry as geometry
from build_score_previews import prepare
from build_sheet_revisions_v5 import CATALOGS

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
STYLE=ROOT/'scripts/engraving/practice-review-v1.mss'
WORK=ROOT/'.tmp/practice-notation-v6'
MUSE='C:/Program Files/MuseScore 4/bin/MuseScore4.exe'
def read(path):return json.loads(path.read_text(encoding='utf-8'))
def write(path,data):path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def digest(data):return hashlib.sha256(data).hexdigest()
def put(path,data,tracked):
    relative=path.relative_to(ROOT).as_posix()
    if relative in tracked and path.exists() and path.read_bytes()!=data:
        raise RuntimeError('Published assets are immutable; publish a new version instead: '+relative)
    path.write_bytes(data)
def put_json(path,value,tracked):
    put(path,(json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8'),tracked)
def current():
    result={}
    for name in CATALOGS+['sheet-revisions-v5.json']:
        for item in read(CONTENT/name):
            q=item['metadata'];old=result.get(q['id'])
            if old is None or q['version']>old['metadata']['version']:result[q['id']]=item
    return list(result.values())
def xml(path):
    with zipfile.ZipFile(path) as z:
        container=ET.fromstring(z.read('META-INF/container.xml'))
        name=next(e.get('full-path') for e in container.iter() if e.tag.rsplit('}',1)[-1]=='rootfile')
        root=ET.fromstring(z.read(name))
    for e in root.iter():e.tag=e.tag.rsplit('}',1)[-1]
    return root
def native(jobs,label,style=None):
    for offset in range(0,len(jobs),80):
        batch=jobs[offset:offset+80];path=WORK/'jobs.json';write(path,batch)
        command=[MUSE,'-T','12']
        if style:command+=['-S',str(style)]
        command+=['-j',str(path)]
        for attempt in range(3):
            with (WORK/'render.log').open('ab') as log:
                proc=subprocess.run(command,stdout=log,stderr=log,timeout=240,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            def produced(job):
                return all(Path(name).exists() or (Path(name).suffix=='.svg' and Path(name).with_name(Path(name).stem+'-1.svg').exists()) for name in job['out'])
            missing=[job for job in batch if not produced(job)]
            if not missing:break
            write(path,missing)
        else:raise RuntimeError(f'{label} failed ({proc.returncode}): {missing[0]["in"]}')
        print(f'{label}: {min(offset+80,len(jobs))}/{len(jobs)}',flush=True)
def lock(source,dest):
    tree=ET.parse(source);score=tree.find('Score');measures=score.findall('./Staff/Measure')
    if len(measures)!=8:raise ValueError('Expected 8 measures: '+str(source))
    for n in list(score.findall('SystemLocks')):score.remove(n)
    for staff in score.findall('Staff'):
        for box in list(staff.findall('VBox')):staff.remove(box)
    for m in measures:
        for n in list(m.findall('LayoutBreak')):m.remove(n)
    locks=ET.SubElement(score,'SystemLocks')
    for a,b in [(0,3),(4,7)]:
        l=ET.SubElement(locks,'systemLock');ET.SubElement(l,'startMeasure').text=measures[a].findtext('eid');ET.SubElement(l,'endMeasure').text=measures[b].findtext('eid')
    tree.write(dest,encoding='utf-8',xml_declaration=True)
def build():
    version=subprocess.run([MUSE,'--long-version'],capture_output=True,text=True,timeout=30,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    if '4.6.3' not in version.stdout+version.stderr:raise RuntimeError('This asset version pins MuseScore Studio 4.6.3.')
    WORK.mkdir(parents=True,exist_ok=True);items=current();jobs=[];combos={}
    for item in items:
        q=item['metadata'];sha=q['score_assets']['main']['sha256'];folder=WORK/sha;folder.mkdir(exist_ok=True)
        meter=q['time_signature'];b,u,f=meter['numerator'],meter['denominator'],q['key_signature']['fifths'];combos[(b,u,f)]=True
        if not (folder/'source.mscx').exists():
            root=prepare(xml(CONTENT/item['main_path']))
            for m in root.findall('./part/measure'):
                for p in list(m.findall('print')):m.remove(p)
            root.findall('./part/measure')[4].insert(0,ET.Element('print',{'new-system':'yes'}))
            ET.ElementTree(root).write(folder/'source.musicxml',encoding='utf-8',xml_declaration=True)
            jobs.append({'in':str(folder/'source.musicxml'),'out':[str(folder/'source.mscx')]})
    native(jobs,'Import',STYLE)
    blankdir=WORK/'blanks';blankdir.mkdir(exist_ok=True);jobs=[]
    for b,u,f in sorted(combos):
        p=blankdir/f'{b}-{u}-key{f}'
        if p.with_name(p.name+'-1.svg').exists():continue
        score=ET.Element('score-partwise',{'version':'4.0'});parts=ET.SubElement(score,'part-list');sp=ET.SubElement(parts,'score-part',{'id':'P1'});ET.SubElement(sp,'part-name').text='';part=ET.SubElement(score,'part',{'id':'P1'})
        for i in range(1,9):
            m=ET.SubElement(part,'measure',{'number':str(i)})
            if i==5:ET.SubElement(m,'print',{'new-system':'yes'})
            if i==1:
                a=ET.SubElement(m,'attributes');ET.SubElement(a,'divisions').text='480';k=ET.SubElement(a,'key');ET.SubElement(k,'fifths').text=str(f);t=ET.SubElement(a,'time');ET.SubElement(t,'beats').text=str(b);ET.SubElement(t,'beat-type').text=str(u);c=ET.SubElement(a,'clef');ET.SubElement(c,'sign').text='G';ET.SubElement(c,'line').text='2'
            n=ET.SubElement(m,'note',{'print-object':'no','print-spacing':'yes'});ET.SubElement(n,'rest',{'measure':'yes'});ET.SubElement(n,'duration').text=str(b*480*4//u)
        ET.ElementTree(score).write(p.with_suffix('.musicxml'),encoding='utf-8',xml_declaration=True)
        jobs.append({'in':str(p.with_suffix('.musicxml')),'out':[str(p.with_suffix('.svg'))]})
    native(jobs,'Blank',STYLE)
    jobs=[]
    for item in items:
        folder=WORK/item['metadata']['score_assets']['main']['sha256']
        if not (folder/'natural-1.svg').exists():
            lock(folder/'source.mscx',folder/'natural.mscx');jobs.append({'in':str(folder/'natural.mscx'),'out':[str(folder/'natural.svg')]})
    native(jobs,'4+4 layout')
    # Rounds are cached independently. Poorly spaced or unconverged candidates
    # fall back as a whole question, never a mixture of equal and natural bars.
    pending=[]
    for item in items:
        q=item['metadata'];folder=WORK/q['score_assets']['main']['sha256']
        if (folder/'decision.json').exists():continue
        _,m=geometry.canonical_reference(folder/'natural-1.svg')
        if (m['minimum_notehead_centres_sp'] or 0)<1.6:
            write(folder/'decision.json',{'mode':'natural','reason':'dense-native-layout','metrics':m});continue
        pending.append((item,[1.]*8))
    for iteration in range(1,10):
        jobs=[];next_pending=[]
        for item,stretch in pending:
            folder=WORK/item['metadata']['score_assets']['main']['sha256'];source=folder/f'equal-{iteration}.mscx'
            if (folder/f'equal-{iteration}-1.svg').exists():continue
            tree=ET.parse(folder/'natural.mscx');measures=tree.findall('./Score/Staff/Measure')
            # An invisible time signature reserves the same header space below.
            original=measures[0].find('./voice/TimeSig')
            if original is not None:
                time=copy.deepcopy(original);ET.SubElement(time,'visible').text='0';measures[4].find('voice').insert(0,time)
            for measure,value in zip(measures,stretch):
                n=measure.find('stretch')
                if n is None:n=ET.SubElement(measure,'stretch')
                n.text=f'{value:.8f}'
            tree.write(source,encoding='utf-8',xml_declaration=True)
            jobs.append({'in':str(source),'out':[str(source.with_suffix('.svg'))]})
        native(jobs,f'Equal {iteration}')
        for item,stretch in pending:
            q=item['metadata'];folder=WORK/q['score_assets']['main']['sha256'];meter=q['time_signature'];b,u,f=meter['numerator'],meter['denominator'],q['key_signature']['fifths']
            _,layout=geometry.canonical_blank(blankdir/f'{b}-{u}-key{f}-1.svg',b,u,f)
            _,m=geometry.canonical_reference(folder/f'equal-{iteration}-1.svg');target=layout['systems'][0]['barline_x']
            error=max(abs(a-t) for row in m['barlines'] for a,t in zip(row,target))
            if error<2 and (m['minimum_notehead_centres_sp'] or 0)>=1.6:
                write(folder/'decision.json',{'mode':'equal','source':f'equal-{iteration}-1.svg','max_barline_error':error,'metrics':m});continue
            if iteration==9:
                write(folder/'decision.json',{'mode':'natural','reason':'spacing-or-alignment','equal_error':error});continue
            for row_index,row in enumerate(m['barlines']):
                for i in range(4):
                    k=row_index*4+i;stretch[k]=max(.025,min(50,stretch[k]*(target[i+1]-target[i])/(row[i+1]-row[i])))
            next_pending.append((item,stretch))
        pending=next_pending
        print(f'Equal {iteration}: {len(pending)} remaining',flush=True)
        if not pending:break
    finalize()

def finalize():
    items=current();blankdir=WORK/'blanks'
    combos={(q['metadata']['time_signature']['numerator'],q['metadata']['time_signature']['denominator'],q['metadata']['key_signature']['fifths']) for q in items}
    raster=[];records={};layouts={}
    for b,u,f in sorted(combos):
        svg,layout=geometry.canonical_blank(blankdir/f'{b}-{u}-key{f}-1.svg',b,u,f)
        layout['id']=f'staff-8bars-{b}-{u}-key{f}-v6';layout['renderer']='MuseScore Studio 4.6.3 / Leland'
        svgpath=blankdir/(layout['id']+'.svg');ET.ElementTree(svg).write(svgpath,encoding='utf-8',xml_declaration=True)
        layouts[layout['id']]=layout;raster.append({'in':str(svgpath),'out':str(svgpath.with_name(svgpath.stem+'-final.png')),'width':2660,'height':1692})
    for item in items:
        q=item['metadata'];sha=q['score_assets']['main']['sha256'];folder=WORK/sha;decision=read(folder/'decision.json')
        measures=ET.parse(folder/'source.musicxml').findall('./part/measure')
        end=measures[3].findall('note')[-1];start=measures[4].findall('note')[0]
        crosses=any(t.get('type')=='start' for t in end.findall('tie')) and any(t.get('type')=='stop' for t in start.findall('tie'))
        if decision['mode']=='equal' and crosses:
            decision={'mode':'natural','reason':'cross-system-tie'};write(folder/'decision.json',decision)
        source=decision.get('source','natural-1.svg')
        svg,metrics=geometry.review_reference(folder/source)
        path=folder/'display.svg';old=path.read_bytes() if path.exists() else None
        data=ET.tostring(svg,encoding='utf-8',xml_declaration=True);path.write_bytes(data)
        output=folder/'display-final.png'
        if old!=data and output.exists():output.unlink()  # Only this task's cached file.
        if old==data and (folder/'display.png').exists() and not output.exists():shutil.copyfile(folder/'display.png',output)
        records[sha]={'resource':'practice-reference-v2-'+sha[:20],'renderer':'MuseScore Studio 4.6.3','layout_mode':decision['mode'],
            'geometry':{'logical_width':1330,'logical_height':574,'systems':[{'index':i+1,'first_measure':i*4+1,'last_measure':i*4+4,'staff_line_y':[top+j*12 for j in range(5)],'barline_x':bars} for i,(top,bars) in enumerate(zip([164,340],metrics['barlines']))]}}
        raster.append({'in':str(folder/'display.svg'),'out':str(output),'width':2660,'height':1148})
    write(WORK/'raster-jobs.json',raster);write(WORK/'records.json',records);write(WORK/'layouts.json',layouts)
    print(f'Ready to rasterize {len(raster)} images.',flush=True)
def publish():
    tracked=set(subprocess.run(['git','ls-files'],cwd=ROOT,capture_output=True,text=True,check=True).stdout.splitlines())
    records=read(WORK/'records.json');layouts=read(WORK/'layouts.json');revisions=[]
    for key,layout in layouts.items():
        layout.pop('renderer',None)
        source=WORK/'blanks'/(key+'-final.png');data=source.read_bytes();layout['template_sha256']=digest(data);layout['template_png_url']=f'https://api.sori.example/assets/sheets/{key}.png'
        put_json(CONTENT/'sheets'/(key+'.layout.json'),layout,tracked)
        put(CONTENT/'sheets'/(key+'.svg'),(WORK/'blanks'/(key+'.svg')).read_bytes(),tracked)
        put(CONTENT/'sheets'/(key+'.png'),data,tracked);put(RESOURCES/(key+'.pngdata'),data,tracked)
    for sha,record in records.items():
        data=(WORK/sha/'display-final.png').read_bytes();w,h=struct.unpack('>II',data[16:24]);record.update(content_type='image/png',sha256=digest(data),size_bytes=len(data),pixel_width=w,pixel_height=h)
        put(CONTENT/'engraving'/(record['resource']+'.png'),data,tracked);put(RESOURCES/(record['resource']+'.pngdata'),data,tracked)
    for original in current():
        item=copy.deepcopy(original);q=item['metadata'];q['version']+=1;meter=q['time_signature'];key=f'staff-8bars-{meter["numerator"]}-{meter["denominator"]}-key{q["key_signature"]["fifths"]}-v6'
        q['sheet_layout']=layouts[key];q['reference_display']=records[q['score_assets']['main']['sha256']]
        for asset in q['score_assets'].values():asset['url']=asset['url'].replace(f'/versions/{q["version"]-1}/',f'/versions/{q["version"]}/')
        revisions.append(item)
    put_json(CONTENT/'sheet-revisions-v6.json',revisions,tracked);put_json(RESOURCES/'sheet-revisions-v6.json',[i['metadata'] for i in revisions],tracked)
    audit={}
    for sha,record in records.items():
        decision=read(WORK/sha/'decision.json')
        metrics=decision.get('metrics')
        if metrics is None:_,metrics=geometry.canonical_reference(WORK/sha/'natural-1.svg')
        audit[sha]={'mode':record['layout_mode'],'reason':decision.get('reason','native-stretch-aligned'),
            'minimum_notehead_centres_sp':metrics['minimum_notehead_centres_sp'],'max_barline_error':decision.get('max_barline_error')}
    put_json(CONTENT/'engraving/practice-layout-v2.json',{'version':2,'style_sha256':digest(STYLE.read_bytes()),'scores':records,'audit':audit},tracked)
    put(RESOURCES/'practice-layout-v2.json',(CONTENT/'engraving/practice-layout-v2.json').read_bytes(),tracked)
    from collections import Counter
    print(json.dumps({'questions':len(revisions),'sheets':len(layouts),'layouts':dict(Counter(r['layout_mode'] for r in records.values()))}),flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('phase',choices=['build','finalize','raster','compact','publish']);p.add_argument('--musescore',default=MUSE);a=p.parse_args();MUSE=a.musescore
    if a.phase=='build':build()
    elif a.phase=='finalize':finalize()
    elif a.phase in ['raster','compact']:
        if a.phase=='raster':subprocess.run([shutil.which('node') or 'node',str(ROOT/'scripts/rasterize_notation.cjs'),str(WORK/'raster-jobs.json')],check=True)
        subprocess.run([shutil.which('node') or 'node',str(ROOT/'scripts/compact_notation_png.cjs'),str(WORK/'raster-jobs.json')],check=True)
    else:publish()
