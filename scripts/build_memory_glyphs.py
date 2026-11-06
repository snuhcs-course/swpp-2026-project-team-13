"""Freeze MuseScore/Leland glyph outlines for offline, editable Memory run notation.

Only glyphs are frozen. Both the reference and the learner's answer use the same
runtime spacing, stems, beams and tie renderer; arbitrary piano input stays editable.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
from build_rhythm_engraving import commands

ROOT = Path(__file__).resolve().parents[1]
STYLE = '<?xml version="1.0"?><museScore version="4.60"><Style><pageWidth>5</pageWidth><pageHeight>3</pageHeight><pagePrintableWidth>4.6</pagePrintableWidth><showMeasureNumber>0</showMeasureNumber><musicalSymbolFont>Leland</musicalSymbolFont></Style></museScore>'
TYPES = {"whole":1920,"half":960,"quarter":480,"eighth":240,"16th":120,"32nd":60,"64th":30}


def source(kind, rest=False, clef="G", accidental=None, down=False):
    pitch = '<rest/>' if rest else '<pitch><step>B</step><alter>'+str(accidental or 0)+'</alter><octave>4</octave></pitch>'
    accidental_xml = '' if accidental is None else '<accidental>'+{-2:'flat-flat',-1:'flat',0:'natural',1:'sharp',2:'double-sharp'}[accidental]+'</accidental>'
    return f'''<?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name/></score-part></part-list><part id="P1"><measure number="1" implicit="yes"><attributes><divisions>480</divisions><time print-object="no"><beats>4</beats><beat-type>4</beat-type></time><clef><sign>{clef}</sign><line>{2 if clef == 'G' else 4}</line></clef></attributes><note>{pitch}<duration>{TYPES[kind]}</duration><type>{kind}</type>{accidental_xml}<stem>{'down' if down else 'up'}</stem></note></measure></part></score-partwise>'''


def extract(path, kind, anchor="center"):
    svg = ET.parse(path).getroot()
    if not any(n.get('class') == 'StaffLines' for n in svg):
        path = path.with_name(path.name.replace('-1.svg','-2.svg'))
        svg = ET.parse(path).getroot()
    lines = [n for n in svg if n.get('class') == 'StaffLines'][:5]
    ys = sorted(float(n.get('points').split()[0].split(',')[1]) for n in lines)
    scale, middle = 8/(ys[1]-ys[0]), ys[2]
    nodes = [n for n in svg if n.get('class') == kind]
    assert nodes, (path,kind)
    node = nodes[0]
    ops = commands(node.get('d'))
    matrix = [1,0,0,1,0,0]
    if node.get('transform'): matrix = list(map(float,re.findall(r'[-+\d.eE]+',node.get('transform').split('(',1)[1])))
    for op in ops:
        v = op['values']
        for i in range(0,len(v),2):
            x,y = v[i:i+2]; v[i:i+2] = [matrix[0]*x+matrix[2]*y+matrix[4],matrix[1]*x+matrix[3]*y+matrix[5]]
    xs = [op['values'][i] for op in ops for i in range(0,len(op['values']),2)]
    x0,y0 = (min(xs)+max(xs))/2,middle
    if anchor == 'stem':
        stem = next(n for n in svg if n.get('class') == 'Stem')
        pts = list(map(float,re.findall(r'[-+\d.eE]+',stem.get('points'))))
        x0,y0 = pts[-2:]
    for op in ops:
        v = op['values']
        for i in range(0,len(v),2): v[i:i+2] = [round((v[i]-x0)*scale,4),round((v[i+1]-y0)*scale,4)]
    return dict(commands=ops,fill=True,stroke=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--musescore',default='C:/Program Files/MuseScore 4/bin/MuseScore4.exe')
    args = parser.parse_args()
    work = ROOT/'.tmp/memory-glyphs'; work.mkdir(parents=True,exist_ok=True)
    (work/'style.mss').write_text(STYLE,encoding='utf-8')
    specs = {}
    for kind in TYPES:
        specs['note-'+kind] = (source(kind),'Note','center')
        specs['rest-'+kind] = (source(kind,rest=True),'Rest','center')
        if kind in ['eighth','16th','32nd','64th']:
            for down in [False,True]: specs['flag-'+kind+('-down' if down else '-up')] = (source(kind,down=down),'Hook','stem')
    for clef in ['G','F']: specs['clef-'+clef] = (source('whole',clef=clef),'Clef','center')
    for alter in range(-2,3): specs['accidental-'+str(alter)] = (source('quarter',accidental=alter),'Accidental','center')
    jobs = []
    for key,(xml,_,_) in specs.items():
        (work/(key+'.musicxml')).write_text(xml,encoding='utf-8')
        jobs.append({'in':str(work/(key+'.musicxml')),'out':[str(work/(key+'.svg'))]})
    (work/'jobs.json').write_text(json.dumps(jobs),encoding='utf-8')
    opts = {'creationflags':subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    env = dict(os.environ)
    if os.name != 'nt': env.setdefault('QT_QPA_PLATFORM','offscreen')
    subprocess.run([args.musescore,'-t','-F','--session-type','converter','-T','12','-S',str(work/'style.mss'),'--sound-profile','MuseScore Basic','-j',str(work/'jobs.json')],check=True,capture_output=True,timeout=180,env=env,**opts)
    glyphs = {key:extract(work/(key+'-1.svg'),kind,anchor) for key,(_,kind,anchor) in specs.items()}
    output = dict(renderer='MuseScore Studio 4.6.3 / Leland',staff_space=8,style_sha256=hashlib.sha256(STYLE.encode()).hexdigest(),glyphs=glyphs)
    destination = ROOT/'frontend/IPadApp/IPadApp/Resources/memory-glyphs-v1.json'
    destination.write_text(json.dumps(output,separators=(',',':'))+'\n',encoding='utf-8')
    print(f'{len(glyphs)} offline glyphs -> {destination.name}')


if __name__ == '__main__': main()
