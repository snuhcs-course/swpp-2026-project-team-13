#!/usr/bin/env python3
"""Generate the original, fixed SORI piano-like additive SoundFont (no external samples).
Uses only the Python standard library; committed bytes are the canonical v1 resource.
"""
import math, struct, hashlib, json
from pathlib import Path

def chunk(tag, payload):
    return tag.encode('ascii') + struct.pack('<I', len(payload)) + payload + (b'\0' if len(payload) % 2 else b'')
def listing(kind, data): return chunk('LIST', kind.encode() + data)
def name(value): return value.encode('ascii').ljust(20, b'\0')[:20]
def gen(op, amount): return struct.pack('<HH', op, amount & 65535)

def generate():
    rate = 22050; length = rate * 6
    samples = bytearray(); headers = bytearray(); igen = bytearray(); ibag = bytearray()
    # Each supported MIDI key gets its own precisely tuned sample; no pitch remapping.
    for index, key in enumerate(range(48,85)):
        offset = len(samples)//2
        frequency = 440 * 2 ** ((key - 69)/12)
        pcm = bytearray(length * 2)
        for i in range(length):
            t = i / rate
            attack = min(1.0, t / .003)
            value = 0.0
            for harmonic, weight in [(1,1.0),(2,.48),(3,.24),(4,.13),(5,.07),(6,.035)]:
                if frequency * harmonic < rate * .45:
                    value += weight * math.sin(2 * math.pi * frequency * harmonic * t) * math.exp(-t * (.70 + harmonic * .36))
            value *= attack * min(1.0, (6-t)/.05) * .47
            struct.pack_into('<h', pcm, i*2, round(max(-1, min(1, value)) * 32767))
        samples += pcm + b'\0' * 92
        headers += struct.pack('<20sIIIIIBbHH', name('SORI-%d'%key), offset, offset+length, offset, offset+length, rate, key, 0, 0, 1)
        ibag += struct.pack('<HH', len(igen)//4, 0)
        igen += gen(43, key | (key << 8)) + gen(34, -12000) + gen(38, -3000) + gen(54, 0) + gen(53,index)
    ibag += struct.pack('<HH',len(igen)//4,0)
    igen += gen(0,0)
    headers += struct.pack('<20sIIIIIBbHH',name('EOS'),len(samples)//2,len(samples)//2,0,0,rate,0,0,0,1)
    info = chunk('ifil',struct.pack('<HH',2,1)) + chunk('isng',b'EMU8000\0') + chunk('INAM',b'SORI Piano v1\0') + chunk('ICOP',b'Original generated synthesis; CC0-1.0\0')
    phdr = struct.pack('<20sHHHIII',name('SORI Piano'),0,0,0,0,0,0)+struct.pack('<20sHHHIII',name('EOP'),0,0,1,0,0,0)
    pbag = struct.pack('<HHHH',0,0,1,0)
    pgen = gen(41,0)+gen(0,0)
    inst = struct.pack('<20sH',name('SORI Piano'),0)+struct.pack('<20sH',name('EOI'),37)
    pdta = b''.join([chunk('phdr',phdr),chunk('pbag',pbag),chunk('pmod',bytes(10)),chunk('pgen',pgen),chunk('inst',inst),chunk('ibag',ibag),chunk('imod',bytes(10)),chunk('igen',igen),chunk('shdr',headers)])
    payload = b'sfbk'+listing('INFO',info)+listing('sdta',chunk('smpl',samples))+listing('pdta',pdta)
    return chunk('RIFF',payload)

if __name__=='__main__':
    out=Path(__file__).resolve().parents[1]/'IPadApp/IPadApp/Resources'
    data=generate(); (out/'sori-piano-v1.sf2').write_bytes(data)
    manifest={'id':'sori-piano-v1','version':1,'sha256':hashlib.sha256(data).hexdigest(),'size_bytes':len(data),'resource':'sori-piano-v1.sf2','license':'CC0-1.0','provenance':'Original mathematical additive synthesis; no third-party samples. Piano-like synthesized timbre, not a recorded acoustic piano.','program':0,'bank_msb':121,'bank_lsb':0,'gain_db':-6,'sample_rate_hz':22050,'midi_range':[48,84],'tuning_hz':440}
    (out/'instrument-profile.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(manifest)
