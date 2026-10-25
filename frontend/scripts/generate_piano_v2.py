"""Original struck-string piano synthesis v2. No third-party samples or dependencies."""
import hashlib
import json
import math
from pathlib import Path
import struct
import wave
from generate_piano import chunk, listing, name, gen

RATE = 22050
SECONDS = 4
OUT = Path(__file__).resolve().parents[1] / "IPadApp/IPadApp/Resources"


def note_pcm(key):
    frequency = 440 * 2 ** ((key-69)/12)
    # Damped inharmonic string partials, with paired strings and a short felt-hammer transient.
    partials = []
    for harmonic in range(1, 19):
        hz = frequency * harmonic * math.sqrt(1 + 0.00006 * harmonic * harmonic)
        if hz >= RATE * 0.45:
            break
        weight = math.exp(-harmonic / 6) / harmonic ** 0.65
        decay = 0.55 + harmonic * 0.38 + frequency/1800
        voices = [(0,0.65),(-1.8,0.175),(1.4,0.175)] if harmonic <= 4 else [(0,1)]
        for cents, gain in voices:
            angular = 2*math.pi*hz*2**(cents/1200)/RATE
            damping = math.exp(-decay/RATE)
            partials.append([2*damping*math.cos(angular),damping*damping,0,
                             math.sin(angular)*damping*weight*gain])
    values = []
    seed = 92831 + key
    for index in range(RATE*SECONDS):
        t = index/RATE
        value = 0
        for state in partials:
            next_value = state[0]*state[3]-state[1]*state[2]
            state[2],state[3] = state[3],next_value
            value += next_value
        seed = (1664525*seed+1013904223) & 0xffffffff
        noise = (seed/2147483648-1) * 0.045 * math.exp(-t*160)
        value = (value+noise)*min(1,t/0.002)*min(1,(SECONDS-t)/0.03)
        values.append(value)
    scale = 0.82*32767/max(abs(v) for v in values)
    return b"".join(struct.pack("<h",round(v*scale)) for v in values)


def generate():
    samples=bytearray();headers=bytearray();igen=bytearray();ibag=bytearray()
    previews={}
    for index,key in enumerate(range(48,85)):
        pcm=note_pcm(key);offset=len(samples)//2;length=len(pcm)//2
        samples+=pcm+b"\0"*92
        headers+=struct.pack("<20sIIIIIBbHH",name(f"SORI-Piano2-{key}"),offset,offset+length,offset,offset+length,RATE,key,0,0,1)
        ibag+=struct.pack("<HH",len(igen)//4,0)
        igen+=gen(43,key|(key<<8))+gen(34,-12000)+gen(38,-2400)+gen(54,0)+gen(53,index)
        if key in (60,62,64,65,67,69,71,72):
            previews[key]=pcm
    ibag+=struct.pack("<HH",len(igen)//4,0);igen+=gen(0,0)
    headers+=struct.pack("<20sIIIIIBbHH",name("EOS"),len(samples)//2,len(samples)//2,0,0,RATE,0,0,0,1)
    info=chunk("ifil",struct.pack("<HH",2,1))+chunk("isng",b"EMU8000\0")+chunk("INAM",b"SORI Struck Piano v2\0")+chunk("ICOP",b"Original generated synthesis; CC0-1.0\0")
    phdr=struct.pack("<20sHHHIII",name("SORI Piano v2"),0,0,0,0,0,0)+struct.pack("<20sHHHIII",name("EOP"),0,0,1,0,0,0)
    pdta=b"".join([chunk("phdr",phdr),chunk("pbag",struct.pack("<HHHH",0,0,1,0)),chunk("pmod",bytes(10)),
        chunk("pgen",gen(41,0)+gen(0,0)),chunk("inst",struct.pack("<20sH",name("SORI Piano v2"),0)+struct.pack("<20sH",name("EOI"),37)),
        chunk("ibag",ibag),chunk("imod",bytes(10)),chunk("igen",igen),chunk("shdr",headers)])
    return chunk("RIFF",b"sfbk"+listing("INFO",info)+listing("sdta",chunk("smpl",samples))+listing("pdta",pdta)),previews


if __name__=="__main__":
    data,previews=generate()
    (OUT/"sori-piano-v2.sf2").write_bytes(data)
    manifest={"id":"sori-piano-v2","version":2,"sha256":hashlib.sha256(data).hexdigest(),"size_bytes":len(data),
        "resource":"sori-piano-v2.sf2","license":"CC0-1.0",
        "provenance":"Original struck-string synthesis with inharmonic partials, paired strings and felt-hammer attack. Synthesized piano; not an acoustic recording.",
        "program":0,"bank_msb":121,"bank_lsb":0,"gain_db":-6,"sample_rate_hz":RATE,"midi_range":[48,84],"tuning_hz":440}
    (OUT/"instrument-profile-v2.json").write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
    preview=Path(__file__).resolve().parents[2]/"dist"
    preview.mkdir(exist_ok=True)
    sequence=[60,62,64,65,67,69,71,72,71,69,67,65,64,62,60]
    with wave.open(str(preview/"piano-v2-preview.wav"),"wb") as output:
        output.setparams((1,2,RATE,0,"NONE","not compressed"))
        for key in sequence:
            segment=bytearray(previews[key][:RATE])
            # A half-second preview per note; fade the cutoff.
            for i in range(len(segment)//2-220,len(segment)//2):
                sample=struct.unpack_from("<h",segment,i*2)[0]
                struct.pack_into("<h",segment,i*2,round(sample*(len(segment)//2-i)/220))
            output.writeframes(segment)
    print("Generated",manifest["resource"],len(data),"bytes;",manifest["sha256"])
