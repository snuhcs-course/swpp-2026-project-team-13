"""Build the offline Melody Run library. Music is preserved; engraving metadata is omitted.

python scripts/import_melody_library.py [--source ../MusicXML] [--limit 48]
Without local MusicXML files, use the workspace's 1,047-exercise source collection.
"""
import argparse
import collections
import csv
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"
BASES = {"whole":1920,"half":960,"quarter":480,"eighth":240,"16th":120,"32nd":60}


def inspect(data):
    if len(data) > 1_048_576 or b"<!ENTITY" in data.upper():
        raise ValueError("unsafe_or_large_xml")
    root = ET.fromstring(data)
    parts = root.findall("part")
    if root.tag != "score-partwise" or len(parts) != 1:
        raise ValueError("not_single_part")
    bars = parts[0].findall("measure")
    if len(bars) != 8:
        raise ValueError("pickup_or_not_eight_bars")
    attrs = bars[0].find("attributes")
    if attrs is None:
        raise ValueError("missing_attributes")
    beats, unit = int(attrs.findtext("time/beats", "0")), int(attrs.findtext("time/beat-type", "0"))
    if not 2 <= beats <= 12 or unit not in (2,4,8):
        raise ValueError("unsupported_meter")
    fifths = int(attrs.findtext("key/fifths", "0"))
    clef, line = attrs.findtext("clef/sign", "G"), attrs.findtext("clef/line", "2")
    if (clef, line) not in (("G","2"),("F","4")) or attrs.find("clef/clef-octave-change") is not None:
        raise ValueError("unsupported_clef")
    if attrs.findtext("staves", "1") != "1" or abs(fifths) > 7:
        raise ValueError("unsupported_staff_or_key")
    ticks, divisions, voices, pitches, attacks, open_tie = beats*1920//unit, 0, set(), [], 0, None
    for i, bar in enumerate(bars):
        if any(bar.find(x) is not None for x in ("backup","forward","barline/repeat","barline/ending")):
            raise ValueError("repeat_or_multiple_voices")
        a = bar.find("attributes")
        if a is not None:
            divisions = int(a.findtext("divisions", str(divisions)))
            if i and (a.find("time") is not None or a.find("key") is not None or a.find("clef") is not None):
                if a.findtext("time/beats",str(beats)) != str(beats) or a.findtext("time/beat-type",str(unit)) != str(unit) or a.findtext("key/fifths",str(fifths)) != str(fifths) or a.findtext("clef/sign",clef) != clef:
                    raise ValueError("changing_attributes")
        if divisions <= 0:
            raise ValueError("invalid_divisions")
        offset = Fraction()
        for n in bar.findall("note"):
            if n.find("chord") is not None or n.find("grace") is not None:
                raise ValueError("chord_or_grace")
            voices.add(n.findtext("voice", "1"))
            if len(voices) != 1 or n.findtext("staff", "1") != "1":
                raise ValueError("multiple_voices")
            duration = Fraction(int(n.findtext("duration", "0"))*480, divisions)
            if duration <= 0 or duration.denominator != 1:
                raise ValueError("unsupported_rhythm")
            rest = n.find("rest") is not None
            note_type = n.findtext("type", "")
            if not note_type and rest:
                note_type = next((k for k,v in BASES.items() if v == duration), "whole")
            actual, normal = int(n.findtext("time-modification/actual-notes", "1")), int(n.findtext("time-modification/normal-notes", "1"))
            dots = len(n.findall("dot"))
            if note_type not in BASES or not 1 <= actual <= 16 or not 1 <= normal <= 16 or dots > 2:
                raise ValueError("unsupported_note_type")
            if not (rest and n.find("rest").get("measure") == "yes") and duration != Fraction(BASES[note_type]*normal,actual)*sum(Fraction(1,2**j) for j in range(dots+1)):
                raise ValueError("inconsistent_rhythm")
            midi = None
            if not rest:
                step, octave, alter = n.findtext("pitch/step"), int(n.findtext("pitch/octave","-1")), int(n.findtext("pitch/alter","0"))
                if step not in "CDEFGAB" or not 1 <= octave <= 7 or not -2 <= alter <= 2:
                    raise ValueError("unsupported_pitch")
                midi = (octave+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[step]+alter
                if not 24 <= midi <= 108:
                    raise ValueError("unsupported_range")
                pitches.append(midi)
            ties = {t.get("type") for t in n.findall("tie")}
            if open_tie is not None:
                if "stop" not in ties or midi != open_tie:
                    raise ValueError("broken_tie")
            elif "stop" in ties:
                raise ValueError("broken_tie")
            elif midi is not None:
                attacks += 1
            open_tie = midi if "start" in ties else None
            offset += duration
        if offset != ticks:
            raise ValueError("pickup_or_incomplete_bar")
    if not pitches or max(pitches)-min(pitches) > 36 or open_tie is not None:
        raise ValueError("range_or_unfinished_tie")
    return root, dict(beats=beats,beatType=unit,noteCount=attacks,lowestMidi=min(pitches),highestMidi=max(pitches))


def compact(root):
    # Keep every note, pitch, duration, key, meter, tie, beam and tuplet unchanged.
    keep = {"score-partwise","part-list","score-part","part-name","part","measure","attributes","divisions","key","fifths","mode","time","beats","beat-type","clef","sign","line","staves","note","pitch","step","alter","octave","rest","duration","voice","staff","type","dot","tie","notations","tied","tuplet","beam","time-modification","actual-notes","normal-notes","normal-type","accidental","stem","direction","sound","direction-type","metronome","beat-unit","per-minute"}
    def prune(node):
        for child in list(node):
            if child.tag not in keep:
                node.remove(child)
            else:
                prune(child)
    prune(root)
    ET.indent(root, space=" ")
    return ET.tostring(root,encoding="utf-8",xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",type=Path)
    parser.add_argument("--limit",type=int,default=0)
    parser.add_argument("--append",action="store_true",help="Keep existing questions and add/update the selected source files")
    args = parser.parse_args()
    local = ROOT.parent / "MusicXML"
    source = args.source or local
    paths = sorted([*source.rglob("*.xml"),*source.rglob("*.musicxml")]) if source.exists() else []
    metadata = {}
    if not paths and args.source is None:
        source = ROOT.parent / "ear_training_8bars_1047_XML_only/ear_training_8bars_1047"
    if (source / "problem_list.csv").exists():
        with (source / "problem_list.csv").open(encoding="utf-8-sig") as stream:
            rows = list(csv.DictReader(stream))
        metadata = {r["id"]:r for r in rows}
        paths = [source/r["xml_path"] for r in rows]
    if not paths:
        parser.error("No .xml/.musicxml files found in the source folder")
    existing = json.loads((RESOURCES/"melody-catalog.json").read_text(encoding="utf-8")) if args.append and (RESOURCES/"melody-catalog.json").exists() else []
    catalog, rejected, ids = [], [], set()
    filenames = {q["file"]:q["id"] for q in existing}
    for path in paths:
        try:
            original = path.read_bytes()
            root, info = inspect(original)
            identifier = path.stem
            if identifier in ids:
                identifier += "-"+hashlib.sha256(original).hexdigest()[:8]
            if identifier in ids:
                continue
            ids.add(identifier)
            row = metadata.get(path.stem,{})
            filename = "melody--"+re.sub(r"[^a-zA-Z0-9_-]","_",identifier)+".xml"
            if filename in filenames and filenames[filename] != identifier:
                filename = filename[:-4]+"-"+hashlib.sha256(original).hexdigest()[:8]+".xml"
            filenames[filename] = identifier
            (RESOURCES/filename).write_bytes(compact(root))
            key = row.get("key") or f'{root.findtext("part/measure/attributes/key/fifths","0")} fifths'
            catalog.append(dict(id=identifier,title=identifier,file=filename,key=key,**info,sourceURL=row.get("source_url","")))
            if args.limit and len(catalog) >= args.limit:
                break
        except (ValueError, ET.ParseError, TypeError) as error:
            rejected.append(dict(file=str(path.relative_to(source)),reason=str(error)))
    if args.append:
        merged = {q["id"]:q for q in existing}
        merged.update({q["id"]:q for q in catalog})
        catalog = list(merged.values())
    catalog.sort(key=lambda q:(q["highestMidi"]-q["lowestMidi"],q["noteCount"],q["id"]))
    (RESOURCES/"melody-catalog.json").write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    report = dict(imported=len(catalog),skipped=len(rejected),reasons=dict(collections.Counter(r["reason"] for r in rejected)),files=rejected)
    (ROOT/"docs/melody-import-report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    license_file = source/"SOURCES_AND_LICENSE.md"
    if license_file.exists():
        text = license_file.read_text(encoding="utf-8")
        text += "\n\nMelody Run adaptation: nonmusical layout/lyrics/instrument metadata and DTD declarations omitted; all pitches, rhythms, keys, meters, ties and tuplets preserved. Adapted exercise XML and catalog remain CC BY-SA 4.0.\n"
        (RESOURCES/"melody-source-license.txt").write_text(text,encoding="utf-8")
    print(json.dumps({k:v for k,v in report.items() if k != "files"},ensure_ascii=False))


if __name__ == "__main__":
    main()
