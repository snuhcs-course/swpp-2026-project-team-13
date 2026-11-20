"""Derive verified reference glyphs from the exact published MuseScore export.

Does not render, stretch, replace or republish a score. Ambiguous bars are omitted.
The server sends only the few marked glyphs for an individual grading result.
"""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile
from engraving_geometry import node_box, numbers
from build_rhythm_engraving import commands

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "backend/content"
CATALOGS = ("catalog.json", "classical-catalog.json", "additional-practice-catalog.json", "sheet-revisions.json",
            "brahms-catalog.json", "classical-tempo-revisions.json", "mahler-catalog.json", "practice-bank-catalog.json",
            "sheet-revisions-v5.json", "sheet-revisions-v6.json")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def matrix(node):
    raw = node.get("transform", "")
    if not raw:
        return [1, 0, 0, 1, 0, 0]
    if not raw.startswith("matrix("):
        raise ValueError("unsupported transform")
    result = numbers(raw)
    if len(result) != 6:
        raise ValueError("invalid transform")
    return result


def transform(x, y, mat):
    a, b, c, d, e, f = mat
    return a*x+c*y+e, b*x+d*y+f


def build(item):
    q = item["metadata"]; asset = q["reference_display"]; geometry = asset["geometry"]
    main_sha = q["score_assets"]["main"]["sha256"]
    folder = ROOT / ".tmp/practice-notation-v6" / main_sha
    if not any(p.exists() and digest(p.read_bytes()) == asset["sha256"] for p in (folder/"display-final.png", folder/"display-final.png.compact")):
        raise ValueError("cached render does not match published image")
    data = (CONTENT / item["main_path"]).read_bytes()
    if digest(data) != main_sha:
        raise ValueError("source hash mismatch")
    with zipfile.ZipFile(CONTENT / item["main_path"]) as z:
        container = ET.fromstring(z.read("META-INF/container.xml"))
        path = next(n.get("full-path") for n in container.iter() if n.tag.rsplit("}", 1)[-1] == "rootfile")
        root = ET.fromstring(z.read(path))
    for node in root.iter(): node.tag = node.tag.rsplit("}", 1)[-1]
    if len(root.findall("part")) != 1:
        raise ValueError("not monophonic")
    source = (folder / "display.svg").read_bytes(); svg = ET.fromstring(source)
    w, h = geometry["logical_width"], geometry["logical_height"]
    candidates = {i: [] for i in range(1, 9)}
    for group in svg:
        if not group.get("data-system"): continue
        system = geometry["systems"][int(group.get("data-system"))-1]
        outer = matrix(group)
        for node in group:
            if node.get("class") not in ("Note", "Rest"): continue
            box = node_box(node)
            a, b = transform(box[0], box[1], outer), transform(box[2], box[3], outer)
            cx = (a[0]+b[0])/2
            bar = next((i for i, (left, right) in enumerate(zip(system["barline_x"], system["barline_x"][1:])) if left < cx < right), None)
            if bar is None: continue
            inner = matrix(node); drawing = []
            for command in commands(node.get("d", "")):
                values = command["values"]; out = []
                for i in range(0, len(values), 2):
                    x, y = transform(*transform(values[i], values[i+1], inner), outer)
                    out.extend((round(x/w, 7), round(y/h, 7)))
                drawing.append({"op": command["op"], "values": out})
            candidates[system["first_measure"]+bar].append({"kind": node.get("class"), "commands": drawing,
                "bbox": {"x": a[0]/w, "y": a[1]/h, "width": (b[0]-a[0])/w, "height": (b[1]-a[1])/h}})
    result = {}; clef = ("G", "2")
    for measure, block in enumerate(root.findall("./part/measure"), 1):
        tag = block.find("./attributes/clef")
        if tag is not None: clef = (tag.findtext("sign"), tag.findtext("line"))
        notes = block.findall("note"); marks = sorted(candidates.get(measure, []), key=lambda n: n["bbox"]["x"])
        if clef != ("G", "2") or len(notes) != len(marks) or not notes or any(n.find("chord") is not None or n.find("grace") is not None for n in notes): continue
        valid = True
        for index, (note, mark) in enumerate(zip(notes, marks), 1):
            rest = note.find("rest") is not None
            if rest != (mark["kind"] == "Rest"): valid = False; break
            if not rest:
                system = geometry["systems"][(measure-1)//4]; lines = system["staff_line_y"]
                pitch = note.find("pitch")
                if pitch is None: valid = False; break
                diatonic = int(pitch.findtext("octave"))*7 + "CDEFGAB".index(pitch.findtext("step"))
                expected = lines[-1] - (diatonic-30)*(lines[1]-lines[0])/2
                box = mark["bbox"]; actual = (box["y"]+box["height"]/2)*h
                if abs(expected-actual) > 2: valid = False; break
            mark["note_index"] = index
        if valid: result[str(measure)] = marks
    return {"main_sha256": main_sha, "svg_sha256": digest(source), "measures": result}


def main():
    current = {}
    for name in CATALOGS:
        for item in json.loads((CONTENT/name).read_text(encoding="utf-8")):
            q = item["metadata"]
            if q["id"] not in current or q["version"] > current[q["id"]]["metadata"]["version"]: current[q["id"]] = item
    pool = json.loads((CONTENT/"question-pools.json").read_text(encoding="utf-8"))["records"]
    assets = {}; skipped = []; bars = 0
    for qid, record in pool.items():
        if record["pool"] != "exam": continue
        item = current[qid]
        try:
            result = build(item); assets[item["metadata"]["reference_display"]["sha256"]] = result
            bars += len(result["measures"])
        except (ValueError, OSError, KeyError) as e: skipped.append({"question_id": qid, "reason": str(e)})
    value = {"version": "exam-reference-glyphs-1", "assets": assets, "unmapped": skipped}
    target = CONTENT/"engraving/exam-note-map-v1.json"
    encoded = (json.dumps(value, ensure_ascii=False, separators=(",", ":"))+"\n").encode("utf-8")
    if target.exists() and target.read_bytes() != encoded: raise RuntimeError("Publish a new note-map version instead of changing an existing one")
    target.write_bytes(encoded)
    manifest = {"version": "exam-reference-glyphs-1", "resource": target.name, "sha256": digest(encoded),
                "image_count": len(assets), "verified_measure_count": bars,
                "delivery": "server-only; sparse annotations in grading response"}
    manifest_path = target.with_name("exam-note-map-manifest-v1.json")
    manifest_bytes = (json.dumps(manifest, indent=2)+"\n").encode("utf-8")
    if manifest_path.exists() and manifest_path.read_bytes() != manifest_bytes: raise RuntimeError("Published note-map manifest differs")
    manifest_path.write_bytes(manifest_bytes)
    print(json.dumps({"images": len(assets), "verified_measures": bars, "unmapped_images": len(skipped), "bytes": len(encoded)}))


if __name__ == "__main__": main()
