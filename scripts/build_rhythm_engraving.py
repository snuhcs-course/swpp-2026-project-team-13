"""Freeze MuseScore's rhythm glyphs, spacing and notehead anchors for the iPad.

The game joins these unscaled fragments; it never stretches note spacing to fill
the screen. Only cross-fragment ties are drawn at runtime. No MuseScore runtime
or network access is required in the app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
from fractions import Fraction as F

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"
TOKEN = re.compile(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?")
ARITY = {"M": 2, "L": 2, "C": 6, "Q": 4, "Z": 0}


def commands(text):
    tokens = TOKEN.findall(text)
    result, i, op = [], 0, None
    while i < len(tokens):
        if tokens[i].isalpha():
            op = tokens[i]; i += 1
        if op not in ARITY:
            raise ValueError("Unsupported SVG path operation: " + str(op))
        count = ARITY[op]
        values = [float(x) for x in tokens[i:i + count]]
        if len(values) != count:
            raise ValueError("Truncated SVG path")
        result.append(dict(op=op, values=values)); i += count
        if op == "Z":
            op = None
        elif op == "M":
            op = "L"
    return result


def score(tile):
    score_ = ET.Element("score-partwise", version="4.0")
    parts = ET.SubElement(score_, "part-list")
    part = ET.SubElement(parts, "score-part", id="P1")
    ET.SubElement(part, "part-name").text = ""
    part = ET.SubElement(score_, "part", id="P1")
    measure = ET.SubElement(part, "measure", number="1", implicit="yes")
    attributes = ET.SubElement(measure, "attributes")
    ET.SubElement(attributes, "divisions").text = "480"
    time = ET.SubElement(attributes, "time", {"print-object": "no"})
    duration = F(tile["duration"])
    # A hidden exact signature also works for 2/3-quarter tuplet fragments.
    ET.SubElement(time, "beats").text = str(duration.numerator)
    ET.SubElement(time, "beat-type").text = str(4 * duration.denominator)
    clef = ET.SubElement(attributes, "clef", {"print-object": "no"})
    ET.SubElement(clef, "sign").text = "G"; ET.SubElement(clef, "line").text = "2"
    for index, symbol in enumerate(tile["symbols"]):
        note = ET.SubElement(measure, "note")
        if symbol["rest"]:
            ET.SubElement(note, "rest")
        else:
            pitch = ET.SubElement(note, "pitch")
            ET.SubElement(pitch, "step").text = "B"; ET.SubElement(pitch, "octave").text = "4"
        ET.SubElement(note, "duration").text = str(int(F(symbol["duration"]) * 480))
        previous_tie = index > 0 and tile["symbols"][index - 1]["tie_next"]
        if previous_tie: ET.SubElement(note, "tie", type="stop")
        if symbol["tie_next"]: ET.SubElement(note, "tie", type="start")
        ET.SubElement(note, "type").text = symbol["type"]
        for _ in range(symbol["dots"]): ET.SubElement(note, "dot")
        if symbol["actual"] != symbol["normal"]:
            ratio = ET.SubElement(note, "time-modification")
            ET.SubElement(ratio, "actual-notes").text = str(symbol["actual"])
            ET.SubElement(ratio, "normal-notes").text = str(symbol["normal"])
            ET.SubElement(ratio, "normal-type").text = symbol["type"]
        if not symbol["rest"]: ET.SubElement(note, "stem").text = "up"
        notations = ET.SubElement(note, "notations")
        if previous_tie: ET.SubElement(notations, "tied", type="stop")
        if symbol["tie_next"]: ET.SubElement(notations, "tied", type="start")
        group = symbol["group"]
        if group:
            if index == 0 or tile["symbols"][index - 1]["group"] != group:
                ET.SubElement(notations, "tuplet", type="start", number=str(group), bracket="yes")
            if symbol["group_end"]: ET.SubElement(notations, "tuplet", type="stop", number=str(group))
    return score_


def extract(path, tile):
    svg = ET.parse(path).getroot()
    elements, anchors = [], []
    lines = [n for n in svg if n.get("class") == "StaffLines"]
    staff_y = sorted(float(n.get("points").split()[0].split(",")[1]) for n in lines)
    assert len(staff_y) == 5, (path, staff_y)
    baseline, space = staff_y[2], staff_y[1] - staff_y[0]
    for node in svg:
        kind = node.get("class")
        if kind not in {"Note", "Rest", "Stem", "Hook", "NoteDot", "Beam", "Tie", "Tuplet"}:
            continue
        tag = node.tag.rsplit("}", 1)[-1]
        matrix = [1, 0, 0, 1, 0, 0]
        if node.get("transform"):
            matrix = [float(x) for x in re.findall(r"[-+\d.eE]+", node.get("transform").split("(", 1)[1])]
            assert len(matrix) == 6
        if tag == "path":
            ops = commands(node.get("d"))
        elif tag in ("polyline", "polygon"):
            points = [float(x) for x in re.findall(r"[-+\d.eE]+", node.get("points"))]
            ops = [dict(op="M" if i == 0 else "L", values=points[i:i + 2]) for i in range(0, len(points), 2)]
            if tag == "polygon": ops.append(dict(op="Z", values=[]))
        else:
            raise ValueError("Unsupported MuseScore SVG element: " + tag)
        xs = []
        for op in ops:
            v = op["values"]
            for i in range(0, len(v), 2):
                x, y = v[i:i + 2]
                v[i:i + 2] = [matrix[0] * x + matrix[2] * y + matrix[4], matrix[1] * x + matrix[3] * y + matrix[5]]
                xs.append(v[i])
        if kind in ("Note", "Rest"):
            anchors.append((min(xs) + max(xs)) / 2)
        elements.append(dict(commands=ops, fill=node.get("fill") != "none", stroke=float(node.get("stroke-width", "0"))))
    anchors.sort()
    assert len(anchors) == len(tile["symbols"]), (path.name, len(anchors), len(tile["symbols"]))
    points = [op["values"][i:i + 2] for e in elements for op in e["commands"] for i in range(0, len(op["values"]), 2)]
    left = min(p[0] for p in points)
    scale = 8 / space
    for element in elements:
        element["stroke"] = round(element["stroke"] * scale, 4)
        for op in element["commands"]:
            v = op["values"]
            for i in range(0, len(v), 2):
                v[i:i + 2] = [round((v[i] - left) * scale + 10, 4), round((v[i + 1] - baseline) * scale + 58, 4)]
    return dict(width=round((max(p[0] for p in points) - left) * scale + 22, 4), height=98, baseline=58,
                symbol_xs=[round((x - left) * scale + 10, 4) for x in anchors], paths=elements)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--musescore", default="C:/Program Files/MuseScore 4/bin/MuseScore4.exe")
    parser.add_argument("--sample", type=int)
    parser.add_argument("--catalog-version", choices=("v2", "v3"), default="v2")
    args = parser.parse_args()
    raw = (RESOURCES / ("rhythm-puzzle-" + args.catalog_version + ".json")).read_bytes(); catalog = json.loads(raw)
    work = ROOT / ".tmp/rhythm-engraving"; work.mkdir(parents=True, exist_ok=True)
    style = work / "rhythm.mss"
    style.write_text('<?xml version="1.0"?><museScore version="4.60"><Style><pageWidth>9</pageWidth><pageHeight>4</pageHeight><pagePrintableWidth>8.6</pagePrintableWidth><enableIndentationOnFirstSystem>0</enableIndentationOnFirstSystem><lastSystemFillLimit>1</lastSystemFillLimit><showMeasureNumber>0</showMeasureNumber><showMeasureNumberOne>0</showMeasureNumberOne><musicalSymbolFont>Leland</musicalSymbolFont></Style></museScore>', encoding="utf-8")
    tiles = catalog["tiles"][:args.sample] if args.sample else catalog["tiles"]
    jobs = []
    for t in tiles:
        source = work / (t["id"] + ".musicxml")
        ET.ElementTree(score(t)).write(source, encoding="utf-8", xml_declaration=True)
        jobs.append({"in": str(source), "out": [str(work / (t["id"] + ".svg"))]})
    job_file = work / "jobs.json"; job_file.write_text(json.dumps(jobs), encoding="utf-8")
    opts = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
    env = dict(os.environ)
    if os.name != "nt": env.setdefault("QT_QPA_PLATFORM", "offscreen")
    version = subprocess.run([args.musescore, "--long-version"], capture_output=True, text=True, check=True, timeout=30, env=env, **opts)
    assert "4.6.3" in version.stdout + version.stderr, "Review a MuseScore version change before regenerating"
    subprocess.run([args.musescore, "-t", "-F", "--session-type", "converter", "-T", "12", "-S", str(style), "--sound-profile", "MuseScore Basic", "-j", str(job_file)], capture_output=True, check=True, timeout=45 if args.sample else 600, env=env, **opts)
    drawings = {t["id"]: extract(work / (t["id"] + "-1.svg"), t) for t in tiles}
    result = dict(renderer="MuseScore Studio 4.6.3 / Leland", catalog_sha256=hashlib.sha256(raw).hexdigest(), tiles=drawings)
    data = (json.dumps(result, separators=(",", ":")) + "\n").encode()
    destination = work / "sample.json" if args.sample else RESOURCES / ("rhythm-engraving-" + args.catalog_version + ".json")
    destination.write_bytes(data)
    print(f"MuseScore rhythm drawings: {len(drawings)} tiles, {len(data)} bytes")


if __name__ == "__main__": main()
