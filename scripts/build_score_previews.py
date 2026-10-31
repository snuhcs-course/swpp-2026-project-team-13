"""Pre-render reference scores with MuseScore 4.6.3. Not needed at runtime.
Never render student recognition: its original beaming/accidentals must survive grading.
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

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "backend/content"
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"
STYLE = ROOT / "scripts/engraving/compact-v1.mss"

def notes_signature(score):
    return [(n.findtext("pitch/step"), n.findtext("pitch/alter", "0"), n.findtext("pitch/octave"),
             n.findtext("duration"), n.findtext("type"), len(n.findall("dot")),
             [(b.get("number"), b.text) for b in n.findall("beam")]) for n in score.findall("part/measure/note")]

def prepare(score):
    before = notes_signature(score)
    for tag in ("work", "movement-title"):
        for element in list(score.findall(tag)):
            score.remove(element)
    for part in score.findall("part"):
        previous = {}
        fifths = int(part.findtext("measure/attributes/key/fifths", "0"))
        defaults = {step: str(1 if fifths > 0 else -1) for step in ("FCGDAEB" if fifths > 0 else "BEADGCF")[:abs(fifths)]}
        for number, measure in enumerate(part.findall("measure"), 1):
            for direction in list(measure.findall("direction")):
                measure.remove(direction)
            if number == 5:
                measure.insert(0, ET.Element("print", {"new-system": "yes"}))
            seen, altered = set(), {}
            for note in measure.findall("note"):
                if note.find("pitch") is None:
                    continue
                key = (note.findtext("pitch/step"), note.findtext("pitch/octave"))
                alter = note.findtext("pitch/alter", "0")
                tied = any(t.get("type") == "stop" for t in note.findall("tie"))
                baseline = defaults.get(key[0], "0")
                if key not in seen and previous.get(key, baseline) != baseline and alter == baseline and not tied and note.find("accidental") is None:
                    accidental = ET.Element("accidental", {"cautionary": "yes"})
                    accidental.text = {"0":"natural", "1":"sharp", "-1":"flat"}[baseline]
                    # MusicXML order: after type/dots, before stem/beams/notations.
                    insert = next((i for i, e in enumerate(note) if e.tag in ("time-modification", "stem", "notehead", "staff", "beam", "notations")), len(note))
                    note.insert(insert, accidental)
                seen.add(key)
                altered[key] = alter
            previous = altered
    assert before == notes_signature(score), "Display preparation changed musical content"
    return score

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--musescore", default=shutil.which("MuseScore4") or "C:/Program Files/MuseScore 4/bin/MuseScore4.exe")
    args = parser.parse_args()
    executable = Path(args.musescore)
    if not executable.is_file():
        parser.error("MuseScore 4.6.3 executable not found; pass --musescore")
    work = ROOT / ".tmp/engraving"
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    if os.name != "nt":
        env.setdefault("QT_QPA_PLATFORM", "offscreen")
    style_data = STYLE.read_bytes()
    if b"\r" in style_data:
        parser.error("The hash-pinned stylesheet must use LF line endings; check out compact-v1.mss again before exporting")
    options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
    version = subprocess.run([str(executable), "--long-version"], capture_output=True, text=True, env=env, check=True, timeout=30, **options)
    version_text = version.stdout + version.stderr
    if "4.6.3" not in version_text:
        parser.error("Pinned renderer is MuseScore 4.6.3; review a renderer version upgrade before regenerating assets")
    # Imported final images are already reviewed source artifacts; render only the originals.
    catalog = json.loads((CONTENT / "catalog.json").read_text(encoding="utf-8"))[:3]
    jobs = []
    for index, item in enumerate(catalog, 1):
        with zipfile.ZipFile(CONTENT / item["main_path"]) as archive:
            score = prepare(ET.fromstring(archive.read("score.xml")))
        source = work / ("excerpt-" + str(index) + ".musicxml")
        ET.ElementTree(score).write(source, encoding="utf-8", xml_declaration=True)
        jobs.append({"in": str(source), "out": [str(work / ("excerpt-" + str(index) + ".png")), str(work / ("excerpt-" + str(index) + ".svg"))]})
    job_file = work / "jobs.json"
    job_file.write_text(json.dumps(jobs), encoding="utf-8")
    subprocess.run([str(executable), "-T", "12", "-r", "300", "-S", str(STYLE), "-j", str(job_file)], check=True, timeout=180, env=env, **options)
    target = CONTENT / "engraving"
    target.mkdir(exist_ok=True)
    old = json.loads((CONTENT / "catalog-v1.json").read_text(encoding="utf-8"))
    existing_path = target / "manifest.json"
    existing = json.loads(existing_path.read_text(encoding="utf-8")) if existing_path.exists() else {"scores": {}}
    classical = {key: value for key, value in existing["scores"].items() if value["resource"].startswith("classical-")}
    manifest = {"renderer": "MuseScore Studio 4.6.3", "style": "compact-v1", "style_sha256": hashlib.sha256(style_data).hexdigest(), "scores": classical}
    for index, item in enumerate(catalog, 1):
        name = "excerpt-" + str(index) + "-reference-v1"
        data = (work / ("excerpt-" + str(index) + "-1.png")).read_bytes()
        width, height = struct.unpack(">II", data[16:24])
        assert 2000 <= width <= 3000 and 200 <= height <= 650, "Expected one compact page with two systems"
        (target / (name + ".png")).write_bytes(data)
        (RESOURCES / (name + ".pngdata")).write_bytes(data)
        shutil.copyfile(work / ("excerpt-" + str(index) + "-1.svg"), target / (name + ".svg"))
        asset = {"resource": name, "content_type": "image/png", "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data), "pixel_width": width, "pixel_height": height, "renderer": manifest["renderer"]}
        with zipfile.ZipFile(CONTENT / old[index-1]["main_path"]) as archive:
            legacy = ET.fromstring(archive.read("score.xml"))
        with zipfile.ZipFile(CONTENT / item["main_path"]) as archive:
            current = ET.fromstring(archive.read("score.xml"))
        assert notes_signature(legacy) == notes_signature(current), "Legacy preview requires a separate engraving"
        for version in (old[index-1], item):
            manifest["scores"][version["metadata"]["score_assets"]["main"]["sha256"]] = asset
    (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (RESOURCES / "engraving-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    from import_naver_questions import append_naver
    append_naver(list(catalog), [])
    print("Exported 3 MuseScore reference scores: no measure numbers, 4+4 bars, courtesy naturals. Original MXL files preserved.")

if __name__ == "__main__":
    main()
