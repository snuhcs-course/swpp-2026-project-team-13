"""Build only reviewed, originally complete eight-bar excerpts; never rebuild legacy questions.

Sources, their hashes, and exclusion decisions are checked in under content/source/classical.
No pickup removal, bar cropping, rest padding, pitch transposition, or tie repair is allowed.
"""
import argparse
import copy
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET

import build_question_assets as build

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "backend/content"
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"
SOURCE = CONTENT / "source/classical"
BASES = {"whole":1920,"half":960,"quarter":480,"eighth":240,"16th":120,"32nd":60}
MAJOR = ["Cb","Gb","Db","Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#"]
MINOR = ["Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#","G#","D#","A#"]
METERS = {(2,2),(2,4),(3,4),(4,4),(3,8),(6,8),(7,8),(9,8),(12,8)}


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+"\n",encoding="utf-8")


def signature(root):
    return (int(root.findtext("part/measure/attributes/key/fifths")), root.findtext("part/measure/attributes/key/mode"))


def musical_notes(root):
    divisions = int(root.findtext("part/measure/attributes/divisions"))
    return [(n.find("rest") is not None, n.findtext("pitch/step"), n.findtext("pitch/alter","0"),
             n.findtext("pitch/octave"), Fraction(int(n.findtext("duration")),divisions),
             n.findtext("type"),len(n.findall("dot")),tuple(t.get("type") for t in n.findall("tie")),
             tuple((t.tag,t.text.strip()) for t in n.findall("time-modification/*")))
            for n in root.findall("part/measure/note")]


def validate_source(root):
    parts = root.findall("part")
    assert len(parts) == 1, "Exactly one original melodic part is required"
    bars = parts[0].findall("measure")
    assert len(bars) == 8, "The source itself must contain exactly eight measures"
    first = bars[0].find("attributes")
    divisions = int(first.findtext("divisions"))
    meter = int(first.findtext("time/beats")),int(first.findtext("time/beat-type"))
    fifths,mode = signature(root)
    assert meter in METERS and -7 <= fifths <= 7 and mode in ("major","minor")
    assert (first.findtext("clef/sign"),first.findtext("clef/line")) == ("G","2")
    expected = Fraction(meter[0]*4,meter[1])
    open_tie = None
    for index,bar in enumerate(bars):
        assert bar.get("implicit") != "yes", "Pickups are excluded"
        assert not any(bar.findall(tag) for tag in ("backup","forward","barline/repeat")), "Polyphony or repeats"
        for attrs in bar.findall("attributes"):
            assert int(attrs.findtext("divisions",str(divisions))) == divisions
            for tag,value in [("key/fifths",str(fifths)),("key/mode",mode),("time/beats",str(meter[0])),("time/beat-type",str(meter[1]))]:
                assert attrs.findtext(tag,value) == value, "Mid-excerpt key/meter changes are excluded"
        length = Fraction(0)
        for note in bar.findall("note"):
            assert note.find("chord") is None and note.find("grace") is None
            assert note.findtext("voice","1") == "1" and note.findtext("staff","1") == "1"
            duration = Fraction(int(note.findtext("duration"))*480,divisions)
            assert duration.denominator == 1
            kind = note.findtext("type"); dots = len(note.findall("dot"))
            assert kind in BASES and dots <= 2
            actual = int(note.findtext("time-modification/actual-notes","1"))
            normal = int(note.findtext("time-modification/normal-notes","1"))
            assert (actual,normal) in ((1,1),(3,2))
            written = sum((Fraction(BASES[kind],2**d) for d in range(dots+1)),Fraction(0))*normal/actual
            assert written == duration, "Rhythm cannot be repaired during import"
            length += duration/480
            pitch = note.find("pitch")
            token = None
            if pitch is not None:
                step = pitch.findtext("step"); alter = int(pitch.findtext("alter","0")); octave = int(pitch.findtext("octave"))
                midi = (octave+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[step]+alter
                assert 48 <= midi <= 95 and -2 <= alter <= 2
                token = (step,alter,octave)
            ties = {t.get("type") for t in note.findall("tie")}
            if open_tie is not None:
                assert "stop" in ties and open_tie == token, "External or broken ties are excluded"
            else:
                assert "stop" not in ties, "Tie begins before excerpt"
            open_tie = token if "start" in ties else None
        assert length == expected, f"Measure {index+1} is incomplete: {length} != {expected}"
    assert open_tie is None, "Tie continues beyond excerpt"
    return meter,fifths,mode


def scale(meter, fifths, mode):
    tonic = (MINOR if mode == "minor" else MAJOR)[fifths+7]
    root,part = build.document(tonic+" "+mode+" reference scale",*meter)
    steps = "CDEFGAB"; start = steps.index(tonic[0]); alterations = {}
    for step in ("FCGDAEB" if fifths >= 0 else "BEADGCF")[:abs(fifths)]:
        alterations[step] = 1 if fifths > 0 else -1
    rising = [(steps[(start+i)%7],4+(start+i)//7) for i in range(8)]
    pitches = rising + list(reversed(rising[:-1]))
    ticks = meter[0]*1920//meter[1]; count = (3600+ticks-1)//ticks; cursor = 0
    for number in range(1,count+1):
        bar = build.child(part,"measure",number=str(number)); used = 0
        if number == 1:
            build.attributes(bar,*meter)
            bar.find("attributes/key/fifths").text = str(fifths); bar.find("attributes/key/mode").text = mode
        while cursor < 15 and used < ticks:
            step,octave = pitches[cursor]
            remaining = ticks-used if cursor == 14 else 240
            chunks = []
            while remaining:
                duration,kind = next((d,k) for k,d in BASES.items() if d <= remaining)
                chunks.append((duration,kind)); remaining -= duration
            for index,(duration,kind) in enumerate(chunks):
                note = build.child(bar,"note"); pitch = build.child(note,"pitch")
                build.child(pitch,"step",step)
                if step in alterations: build.child(pitch,"alter",alterations[step])
                build.child(pitch,"octave",octave); build.child(note,"duration",duration)
                ties = (["stop"] if index else [])+(["start"] if index < len(chunks)-1 else [])
                for tie in ties: build.child(note,"tie",type=tie)
                build.child(note,"type",kind)
                if ties:
                    notation = build.child(note,"notations")
                    for tie in ties: build.child(notation,"tied",type=tie)
                used += duration
            cursor += 1
        assert used == ticks
    assert cursor == 15
    return build.package(root),count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render",action="store_true",help="Generate answer images with the existing pinned MuseScore renderer")
    parser.add_argument("--musescore",default="C:/Program Files/MuseScore 4/bin/MuseScore4.exe")
    args = parser.parse_args()
    provenance = json.loads((SOURCE/"provenance.json").read_text(encoding="utf-8"))
    manifest_path = CONTENT/"engraving/manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    legacy_manifest = copy.deepcopy(manifest["scores"])
    catalog,demo,jobs = [],[],[]
    work = ROOT/".tmp/classical-engraving"; work.mkdir(parents=True,exist_ok=True)
    for order,item in enumerate(provenance["accepted"],1001):
        data = (SOURCE/item["file"]).read_bytes()
        assert hashlib.sha256(data).hexdigest() == item["sha256"]
        original = ET.fromstring(data)
        meter,fifths,mode = validate_source(original)
        assert item["key"] == {"tonic":(MINOR if mode == "minor" else MAJOR)[fifths+7],"mode":mode,"fifths":fifths}
        root,part = build.document(item["title"],*meter)
        divisions = int(original.findtext("part/measure/attributes/divisions"))
        for number,source_bar in enumerate(original.findall("part/measure"),1):
            bar = build.child(part,"measure",number=str(number))
            if number == 1:
                build.attributes(bar,*meter)
                bar.find("attributes/key/fifths").text = str(fifths); bar.find("attributes/key/mode").text = mode
            for source_note in source_bar.findall("note"):
                note = build.child(bar,"note")
                for element in source_note:
                    if element.tag in build.NOTE_TAGS: note.append(copy.deepcopy(element))
                notation = note.find("notations")
                if notation is not None:
                    # Match the existing dictation profile: preserve sounding ties/tuplets,
                    # omit optional performance slurs and articulation marks.
                    for element in list(notation):
                        if element.tag not in ("tied","tuplet"): notation.remove(element)
                note.find("duration").text = str(int(source_note.findtext("duration"))*480//divisions)
        assert musical_notes(original) == musical_notes(root), "Musical content must stay identical"
        main_bytes = build.package(root); scale_bytes,scale_count = scale(meter,fifths,mode)
        question_id = item["question_id"]; folder = f"questions/classical-{item['source_id']}/v1"
        target = CONTENT/folder; target.mkdir(parents=True,exist_ok=True)
        assets = {}
        for kind,value,count in [("main",main_bytes,8),("scale",scale_bytes,scale_count)]:
            (target/(kind+".mxl")).write_bytes(value)
            (RESOURCES/f"classical-{question_id}-{kind}.mxl").write_bytes(value)
            assets[kind] = dict(url=f"https://api.sori.example/api/v1/questions/{question_id}/versions/1/scores/{kind}/",content_type="application/vnd.recordare.musicxml",sha256=hashlib.sha256(value).hexdigest(),size_bytes=len(value),musicxml_version="4.0",profile="sori-monophonic-v4",part_id="P1",measure_count=count,source_tempo_bpm=96)
        layout_id = f"staff-8bars-{meter[0]}-{meter[1]}-key{fifths}-v3"
        png = (CONTENT/"sheets"/(layout_id+".png")).read_bytes()
        (RESOURCES/(layout_id+".pngdata")).write_bytes(png)
        layout = dict(id=layout_id,logical_width=1330,logical_height=846,export_scale=2,pixel_width=2660,pixel_height=1692,
                      template_png_url=f"https://api.sori.example/assets/sheets/{layout_id}.png",template_sha256=hashlib.sha256(png).hexdigest(),
                      systems=[dict(index=1,first_measure=1,last_measure=4,staff_line_y=[164,176,188,200,212],barline_x=[54,450,725,1000,1276]),dict(index=2,first_measure=5,last_measure=8,staff_line_y=[499,511,523,535,547],barline_x=[54,397,690,983,1276])])
        write_json(CONTENT/"sheets"/(layout_id+".layout.json"),layout)
        metadata = dict(id=question_id,version=1,title=item["title"],source="practice",collection="classical",composer=item["composer"],key_signature=item["key"],time_signature=dict(numerator=meter[0],denominator=meter[1]),measure_count=8,recommended_duration_seconds=300,
                        description="클래식 선율 발췌본입니다. 음계와 선율을 듣고 표시된 조표에 맞춰 8마디를 적어보세요. 제출 후 정답 악보와 평가를 확인할 수 있어요.",time_policy="advisory",clef="treble",sheet_layout=layout,content_policy="client_readable_practice",score_visibility="after_submission",score_assets=assets)
        catalog.append(dict(order=order,metadata=metadata,main_path=folder+"/main.mxl",scale_path=folder+"/scale.mxl")); demo.append(metadata)
        if args.render:
            from build_score_previews import prepare
            display = prepare(copy.deepcopy(root))
            source = work/(item["source_id"]+".musicxml")
            ET.ElementTree(display).write(source,encoding="utf-8",xml_declaration=True)
            jobs.append({"in":str(source),"out":[str(work/(item["source_id"]+".png")),str(work/(item["source_id"]+".svg"))]})
    if args.render:
        import os
        env = dict(os.environ)
        if os.name != "nt": env.setdefault("QT_QPA_PLATFORM","offscreen")
        options = {"creationflags":subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
        version = subprocess.run([args.musescore,"--long-version"],capture_output=True,text=True,check=True,timeout=30,env=env,**options)
        assert "4.6.3" in version.stdout+version.stderr, "Use the existing pinned renderer"
        job_file = work/"jobs.json"; write_json(job_file,jobs)
        subprocess.run([args.musescore,"-T","12","-r","300","-S",str(ROOT/"scripts/engraving/compact-v1.mss"),"-j",str(job_file)],check=True,timeout=240,env=env,**options)
        for source,item in zip(provenance["accepted"],catalog):
            name = "classical-"+source["source_id"]+"-reference-v1"
            data = (work/(source["source_id"]+"-1.png")).read_bytes()
            width,height = struct.unpack(">II",data[16:24])
            assert 2000 <= width <= 3000 and 200 <= height <= 750
            (CONTENT/"engraving"/(name+".png")).write_bytes(data)
            (RESOURCES/(name+".pngdata")).write_bytes(data)
            shutil.copyfile(work/(source["source_id"]+"-1.svg"),CONTENT/"engraving"/(name+".svg"))
            manifest["scores"][item["metadata"]["score_assets"]["main"]["sha256"]] = dict(resource=name,content_type="image/png",sha256=hashlib.sha256(data).hexdigest(),size_bytes=len(data),pixel_width=width,pixel_height=height,renderer=manifest["renderer"])
        assert all(manifest["scores"][key] == value for key,value in legacy_manifest.items()), "Never replace an existing reference"
        write_json(manifest_path,manifest); write_json(RESOURCES/"engraving-manifest.json",manifest)
    for item in catalog:
        assert item["metadata"]["score_assets"]["main"]["sha256"] in manifest["scores"], "Generate the MuseScore answer first with --render"
    write_json(CONTENT/"classical-catalog.json",catalog); write_json(RESOURCES/"classical-catalog.json",demo)
    print(f"Built {len(catalog)} strict eight-bar classical questions. Existing 62 exercises were not rebuilt.")


if __name__ == "__main__":
    main()
