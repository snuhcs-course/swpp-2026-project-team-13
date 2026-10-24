"""Build deterministic MXL assets from the three original answer XMLs. Python stdlib only."""
import copy
import hashlib
import json
from pathlib import Path
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "backend" / "content"
RESOURCES = ROOT / "frontend" / "IPadApp" / "IPadApp" / "Resources"
TEMPO = 96
SOURCE_NAMES = ["lead_sheet_p1_01-08.xml", "lead_sheet_p1_09-16.xml", "lead_sheet_p1_17-24.xml"]
NOTE_TAGS = {"pitch", "rest", "duration", "voice", "type", "dot", "accidental", "tie", "notations", "time-modification", "stem", "beam", "staff"}

def child(parent, tag, value=None, **attrs):
    item = ET.SubElement(parent, tag, attrs)
    if value is not None:
        item.text = str(value)
    return item

def document(title, numerator, denominator):
    root = ET.Element("score-partwise", version="4.0")
    child(child(root, "work"), "work-title", title)
    part_list = child(root, "part-list")
    score_part = child(part_list, "score-part", id="P1")
    child(score_part, "part-name", "Piano")
    child(child(score_part, "score-instrument", id="I1"), "instrument-name", "Piano")
    instrument = child(score_part, "midi-instrument", id="I1")
    child(instrument, "midi-channel", 1); child(instrument, "midi-program", 1)
    return root, child(root, "part", id="P1")

def attributes(bar, numerator, denominator):
    a = child(bar, "attributes")
    child(a, "divisions", 480)
    key = child(a, "key"); child(key, "fifths", 0); child(key, "mode", "major")
    time = child(a, "time"); child(time, "beats", numerator); child(time, "beat-type", denominator)
    clef = child(a, "clef"); child(clef, "sign", "G"); child(clef, "line", 2)
    direction = child(bar, "direction")
    metronome = child(child(direction, "direction-type"), "metronome")
    child(metronome, "beat-unit", "quarter"); child(metronome, "per-minute", TEMPO)
    child(direction, "sound", tempo=str(TEMPO))

def package(root):
    ET.indent(root, space="  ")
    score = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    container = b'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="score.xml" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles></container>'
    import io
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, value in [("mimetype", b"application/vnd.recordare.musicxml"), ("META-INF/container.xml", container), ("score.xml", score)]:
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            archive.writestr(info, value)
    return output.getvalue()

def main():
    catalog, demo = [], []
    for index, filename in enumerate(SOURCE_NAMES, 1):
        source = ET.fromstring((CONTENT / "source" / filename).read_bytes())
        original = source.find("part")
        numerator = int(original.findtext("measure/attributes/time/beats"))
        denominator = int(original.findtext("measure/attributes/time/beat-type"))
        title = f"청음 연습 {index} · {numerator}/{denominator}"
        root, part = document(title, numerator, denominator)
        source_notes = []
        for number, original_bar in enumerate(original.findall("measure"), 1):
            bar = child(part, "measure", number=str(number))
            if number == 1:
                attributes(bar, numerator, denominator)
            for original_note in original_bar.findall("note"):
                note = child(bar, "note")
                for item in original_note:
                    if item.tag in NOTE_TAGS:
                        note.append(copy.deepcopy(item))
                source_notes.append((original_note.findtext("pitch/step"), original_note.findtext("pitch/alter", "0"), original_note.findtext("pitch/octave"), original_note.findtext("duration"), original_note.findtext("type"), len(original_note.findall("dot")), ET.tostring(original_note.find("time-modification")) if original_note.find("time-modification") is not None else None))
        assert len(part.findall("measure")) == 8
        built_notes = [(n.findtext("pitch/step"), n.findtext("pitch/alter", "0"), n.findtext("pitch/octave"), n.findtext("duration"), n.findtext("type"), len(n.findall("dot")), ET.tostring(n.find("time-modification")) if n.find("time-modification") is not None else None) for n in part.findall("measure/note")]
        assert source_notes == built_notes, "Normalization changed an answer note"
        main_bytes = package(root)
        scale_root, scale_part = document("C Major Scale", numerator, denominator)
        bar_ticks = numerator * 480 * 4 // denominator
        duration = 480 if (numerator, denominator) == (4,4) else 240
        pitches = [("C",4), ("D",4), ("E",4), ("F",4), ("G",4), ("A",4), ("B",4), ("C",5)]
        cursor = 0
        for number in range(1, 3):
            bar = child(scale_part, "measure", number=str(number))
            if number == 1:
                attributes(bar, numerator, denominator)
            used = 0
            while used < bar_ticks:
                note = child(bar, "note")
                if cursor < len(pitches):
                    step, octave = pitches[cursor]; cursor += 1
                    pitch = child(note, "pitch"); child(pitch, "step", step); child(pitch, "octave", octave)
                    child(note, "duration", duration); child(note, "type", "quarter" if duration == 480 else "eighth")
                    used += duration
                else:
                    child(note, "rest"); child(note, "duration", 480); child(note, "type", "quarter"); used += 480
            assert used == bar_ticks
        assert cursor == 8
        scale_bytes = package(scale_root)
        target = CONTENT / "questions" / f"excerpt-{index}" / "v1"
        target.mkdir(parents=True, exist_ok=True)
        (target / "main.mxl").write_bytes(main_bytes); (target / "scale.mxl").write_bytes(scale_bytes)
        layout_id = f"staff-8bars-{numerator}-{denominator}-v2"
        png = (CONTENT / "sheets" / f"{layout_id}.png").read_bytes()
        layout = {"id": layout_id, "logical_width": 1330, "logical_height": 846, "export_scale": 2, "pixel_width": 2660, "pixel_height": 1692, "template_png_url": f"https://api.sori.example/assets/sheets/{layout_id}.png", "template_sha256": hashlib.sha256(png).hexdigest(), "systems": [{"index": 1, "first_measure": 1, "last_measure": 4, "staff_line_y": [164,176,188,200,212], "barline_x": [54,450,725,1000,1276]}, {"index": 2, "first_measure": 5, "last_measure": 8, "staff_line_y": [499,511,523,535,547], "barline_x": [54,397,690,983,1276]}]}
        question_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://sori.local/questions/lead-sheet-excerpt-{index}"))
        assets = {}
        for kind, value, count in [("main", main_bytes, 8), ("scale", scale_bytes, 2)]:
            assets[kind] = {"url": f"https://api.sori.example/api/v1/questions/{question_id}/versions/1/scores/{kind}/", "content_type": "application/vnd.recordare.musicxml", "sha256": hashlib.sha256(value).hexdigest(), "size_bytes": len(value), "musicxml_version": "4.0", "profile": "sori-monophonic-v2", "part_id": "P1", "measure_count": count}
            (RESOURCES / f"excerpt-{index}-{kind}.mxl").write_bytes(value)
        (RESOURCES / f"{layout_id}.pngdata").write_bytes(png)
        (CONTENT / "sheets" / f"{layout_id}.layout.json").write_text(json.dumps(layout, ensure_ascii=False, indent=2), encoding="utf-8")
        metadata = {"id": question_id, "version": 1, "title": title, "source": "practice", "key_signature": {"tonic": "C", "mode": "major", "fifths": 0}, "time_signature": {"numerator": numerator, "denominator": denominator}, "measure_count": 8, "recommended_duration_seconds": 300, "description": "멜로디를 듣고 빈 오선에 적어보세요. 제출 후 AI 평가와 정답을 확인할 수 있어요.", "time_policy": "advisory", "clef": "treble", "sheet_layout": layout, "content_policy": "client_readable_practice", "score_visibility": "after_submission", "score_assets": assets}
        catalog.append({"order": index, "metadata": metadata, "main_path": f"questions/excerpt-{index}/v1/main.mxl", "scale_path": f"questions/excerpt-{index}/v1/scale.mxl"})
        demo.append(metadata)
    (CONTENT / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2), encoding="utf-8")
    (RESOURCES / "practice-catalog.json").write_text(json.dumps(demo, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Built three question versions; source pitches, durations, dots and tuplets preserved.")

if __name__ == "__main__":
    main()
