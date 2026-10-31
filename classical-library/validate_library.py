from pathlib import Path
from fractions import Fraction as F
import hashlib,json,xml.etree.ElementTree as E
ROOT=Path(__file__).resolve().parent
d=json.loads((ROOT/'library-data.json').read_text(encoding='utf-8'))
errors=[]
for x in d['items']:
    if not x.get('ready'):continue
    r=E.fromstring(x['xml']);bars=r.findall('part/measure');ticks=x['beats']*480*4//x['unit'];open_tie=None
    if len(r.findall('part'))!=1 or len(bars)!=8:errors.append((x['id'],'not eight monophonic bars'))
    for i,b in enumerate(bars):
        if sum(int(n.findtext('duration','0')) for n in b.findall('note'))!=ticks:errors.append((x['id'],i,'measure duration'))
        for n in b.findall('note'):
            duration=int(n.findtext('duration'));kind=n.findtext('type');dots=len(n.findall('dot'));actual=int(n.findtext('time-modification/actual-notes','1'));normal=int(n.findtext('time-modification/normal-notes','1'))
            base={'whole':1920,'half':960,'quarter':480,'eighth':240,'16th':120,'32nd':60,'64th':30}.get(kind)
            full=n.find('rest') is not None and n.find('rest').get('measure')=='yes'
            if not full and (base is None or F(duration)!=F(base)*F((2**(dots+1)-1),2**dots)*F(normal,actual)):errors.append((x['id'],i,'notated duration',kind,duration))
            p=n.find('pitch');pitch=E.tostring(p) if p is not None else None;ties=[t.get('type') for t in n.findall('tie')]
            if 'stop' in ties:
                if open_tie!=pitch:errors.append((x['id'],i,'tie stop without matching start'))
                open_tie=None
            elif open_tie is not None:errors.append((x['id'],i,'interrupted tie'));open_tie=None
            if 'start' in ties:open_tie=pitch
    if open_tie is not None:errors.append((x['id'],'dangling tie'))
    if not all(e['on']>=0 and e['dur']>0 and e['on']+e['dur']<=x['total']+1e-5 for e in x['events']):errors.append((x['id'],'invalid event timing'))
    if (ROOT/'xml'/x['file']).read_text(encoding='utf-8')!=x['xml']:errors.append((x['id'],'XML download differs'))
report=dict(local=sum(not x.get('external') for x in d['items']),eightBars=sum(x.get('ready',False) for x in d['items']),reference=sum(not x.get('ready') and not x.get('external') for x in d['items']),external=sum(bool(x.get('external')) for x in d['items']),errors=errors)
(ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False))
if errors:raise SystemExit(1)
