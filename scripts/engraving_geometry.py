"""Geometry of MuseScore SVG exports, in staff spaces rather than image pixels.

Glyph paths are retained verbatim. Canonicalization only translates each system
and applies one uniform scale; it never stretches notes or handwriting in x.
"""
import copy
import math
import re
import xml.etree.ElementTree as ET

NS='http://www.w3.org/2000/svg'
ET.register_namespace('',NS)
NUM=r'[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?'
def numbers(value):return [float(v) for v in re.findall(NUM,value)]

def points_of_path(value):
    tokens=re.findall(r'[a-df-zA-DF-Z]|'+NUM,value)
    points=[];i=0;command=None;x=y=sx=sy=0
    counts={'M':2,'L':2,'T':2,'H':1,'V':1,'C':6,'S':4,'Q':4,'Z':0}
    while i<len(tokens):
        if tokens[i].isalpha():command=tokens[i];i+=1
        if command is None:raise ValueError('SVG path missing command')
        c=command.upper();relative=command.islower()
        if c=='Z':x,y=sx,sy;command=None;continue
        if c not in counts:raise ValueError('Unsupported SVG path operation '+c)
        count=counts[c];values=list(map(float,tokens[i:i+count]));i+=count
        if len(values)!=count:raise ValueError('Incomplete SVG command')
        if c=='H':x=values[0]+(x if relative else 0);points.append((x,y));continue
        if c=='V':y=values[0]+(y if relative else 0);points.append((x,y));continue
        pairs=[(values[j]+(x if relative else 0),values[j+1]+(y if relative else 0)) for j in range(0,count,2)]
        points.extend(pairs);x,y=pairs[-1]
        if c=='M':sx,sy=x,y;command='l' if relative else 'L'
    return points

def node_box(node):
    if node.tag.rsplit('}',1)[-1]=='path':points=points_of_path(node.get('d',''))
    else:
        values=numbers(node.get('points',''));points=list(zip(values[::2],values[1::2]))
    if not points:return None
    transform=node.get('transform','')
    if transform:
        if not transform.startswith('matrix('):raise ValueError('Unsupported MuseScore transform '+transform)
        a,b,c,d,e,f=numbers(transform)
        points=[(a*x+c*y+e,b*x+d*y+f) for x,y in points]
    xs,ys=zip(*points)
    return min(xs),min(ys),max(xs),max(ys)

def systems(root):
    lines=[]
    for node in root:
        if node.get('class')=='StaffLines':
            x,y,right,_=numbers(node.get('points'));lines.append((x,y,right))
    lines.sort(key=lambda p:p[1]);result=[]
    if len(lines)%5:raise ValueError('Incomplete MuseScore staff')
    for start in range(0,len(lines),5):
        staff=lines[start:start+5];top=staff[0][1];space=staff[1][1]-top;bars=[]
        for node in root:
            if node.get('class')!='BarLine':continue
            x,y,_,_=numbers(node.get('points'))
            if abs(y-top)<space:bars.append(x)
        ordered=[]
        for x in sorted(bars):
            if not ordered or x-ordered[-1]>space*.5:ordered.append(x)
        result.append(dict(left=staff[0][0],right=staff[0][2],top=top,space=space,bars=ordered))
    return result

def music_nodes(root):
    for n in root:
        if n.tag.rsplit('}',1)[-1] not in ('path','polyline','polygon'):continue
        if n.get('fill','').lower() in ('white','#ffffff') and not n.get('class'):continue
        yield n

def system_index(node,staves):
    box=node_box(node)
    if box is None:raise ValueError('Missing SVG geometry')
    cy=(box[1]+box[3])/2
    return min(range(len(staves)),key=lambda i:abs(cy-(staves[i]['top']+2*staves[i]['space'])))

def canonical_reference(path):
    root=path if isinstance(path,ET.Element) else ET.parse(path).getroot();staves=systems(root)
    if len(staves)!=2 or [len(s['bars']) for s in staves]!=[4,4]:
        raise ValueError('Expected exactly 4+4 bars: '+str(path))
    dest=ET.Element('{'+NS+'}svg',{'width':'1330','height':'574','viewBox':'0 0 1330 574'})
    ET.SubElement(dest,'rect',{'width':'1330','height':'574','fill':'white'})
    groups=[];transforms=[]
    for i,s in enumerate(staves):
        scale=12/s['space'];tx=54-s['left']*scale;ty=[164,340][i]-s['top']*scale
        groups.append(ET.SubElement(dest,'g',{'transform':f'matrix({scale},0,0,{scale},{tx},{ty})','data-system':str(i+1)}))
        transforms.append((scale,tx,ty))
    notes=[[],[]]
    for n in music_nodes(root):
        i=system_index(n,staves);groups[i].append(copy.deepcopy(n))
        if n.get('class')=='Note':
            box=node_box(n);scale,tx,ty=transforms[i]
            notes[i].append(tuple(v*scale+(tx if j%2==0 else ty) for j,v in enumerate(box)))
    barlines=[[54]+[54+(x-s['left'])*12/s['space'] for x in s['bars'][:-1]]+[54+(s['right']-s['left'])*12/s['space']] for s in staves]
    # Horizontal separation is an indicator, not a claim that engraving is correct.
    minimum_gap=math.inf
    minimum_centres=math.inf
    for row in notes:
        row.sort(key=lambda b:b[0])
        for a,b in zip(row,row[1:]):
            minimum_gap=min(minimum_gap,b[0]-a[2])
            minimum_centres=min(minimum_centres,(b[0]+b[2]-a[0]-a[2])/2)
    return dest,dict(barlines=barlines,staff_space=12,systems=2,
                     minimum_notehead_gap_sp=minimum_gap/12 if math.isfinite(minimum_gap) else None,
                     minimum_notehead_centres_sp=minimum_centres/12 if math.isfinite(minimum_centres) else None)

def review_reference(path):
    """Remove the generated courtesy of an invisible, unchanged time signature.

    The hidden signature reserves the second system's header. MuseScore can still
    print its courtesy at the end of the first system. Remove only that redundant
    glyph, and move the closing barline into the released trailing space. Notes,
    accidentals and their native internal spacing are never stretched or redrawn.
    Cross-system ties use the untouched natural layout (selected by the builder).
    """
    root=ET.parse(path).getroot();staves=systems(root);affected=set()
    for node in list(root):
        if node.get('class')!='TimeSig':continue
        index=system_index(node,staves);s=staves[index]
        if node_box(node)[0]>(s['left']+s['right'])/2:
            root.remove(node);affected.add(index)
    for index in affected:
        s=staves[index];last=s['bars'][-1];bars=[]
        for node in root:
            if node.get('class')!='BarLine':continue
            x,y,x2,y2=numbers(node.get('points',''))
            if abs(y-s['top'])<s['space'] and abs(x-last)<s['space']*.5:bars.append((node,x,y,x2,y2))
        delta=s['right']-max(b[1] for b in bars)
        for node,x,y,x2,y2 in bars:node.set('points',f'{x+delta} {y} {x2+delta} {y2}')
    return canonical_reference(root)

def canonical_blank(path,beats,unit,fifths):
    root=ET.parse(path).getroot();staves=systems(root);s=staves[0];scale=12/s['space']
    tx=54-s['left']*scale
    glyphs=[n for n in music_nodes(root) if n.get('class') in ('Clef','KeySig','TimeSig') and system_index(n,staves)==0]
    if not any(n.get('class')=='Clef' for n in glyphs) or not any(n.get('class')=='TimeSig' for n in glyphs):
        raise ValueError('MuseScore signature glyphs are missing')
    if any(n.get('class')=='Rest' for n in music_nodes(root)):raise ValueError('Blank score contains visible rests')
    right=max(node_box(n)[2] for n in glyphs)*scale+tx
    music_start=right+16;available=(1276-music_start)/4
    bars=[54]+[round(music_start+i*available,3) for i in (1,2,3)]+[1276]
    dest=ET.Element('{'+NS+'}svg',{'width':'2660','height':'1692','viewBox':'0 0 1330 846'})
    ET.SubElement(dest,'rect',{'width':'1330','height':'846','fill':'white'})
    thickness=float(next(n.get('stroke-width') for n in root if n.get('class')=='StaffLines'))*scale
    bar_thickness=float(next(n.get('stroke-width') for n in root if n.get('class')=='BarLine'))*scale
    for i,top in enumerate([164,340]):
        g=ET.SubElement(dest,'g',{'transform':f'matrix({scale},0,0,{scale},{tx},{top-s["top"]*scale})'})
        for n in glyphs:
            if i and n.get('class')=='TimeSig':continue
            g.append(copy.deepcopy(n))
        for y in [top+j*12 for j in range(5)]:ET.SubElement(dest,'path',{'class':'StaffLines','d':f'M54 {y}H1276','fill':'none','stroke':'black','stroke-width':str(thickness)})
        for x in bars[1:]:ET.SubElement(dest,'path',{'class':'BarLine','d':f'M{x} {top}v48','fill':'none','stroke':'black','stroke-width':str(bar_thickness)})
    layout=dict(id=f'staff-8bars-{beats}-{unit}-key{fifths}-musescore-review',logical_width=1330,logical_height=846,
                pixel_width=2660,pixel_height=1692,export_scale=2,display_height=574,
                systems=[dict(index=i+1,first_measure=i*4+1,last_measure=i*4+4,staff_line_y=[top+j*12 for j in range(5)],barline_x=bars) for i,top in enumerate([164,340])],
                renderer='MuseScore Studio 4.6.3 / Leland; vector glyphs preserved; blank-only canonical grid')
    return dest,layout
