"""Import the supplied final Q001–Q059 transcriptions, then rebuild offline/API assets.

Run once with --source pointing at naver_monophonic_001-059_final.
Subsequent build_question_assets.py runs use the checked-in source, without the archive.
Original recordings are not used: playback follows the app's MIDI/tempo policy.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "backend/content"
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"
SOURCE = CONTENT / "source/naver"


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def scale(numerator, denominator, build):
    root, part = build.document("C reference scale", numerator, denominator)
    bar_ticks = numerator * 480 * 4 // denominator
    count = (15 * 240 + bar_ticks - 1) // bar_ticks
    pitches = [(s, 4) for s in "CDEFGAB"] + [("C", 5)] + [(s, 4) for s in "BAGFEDC"]
    cursor = 0
    for number in range(1, count + 1):
        bar = build.child(part, "measure", number=str(number))
        if number == 1:
            build.attributes(bar, numerator, denominator)
        used = 0
        while cursor < len(pitches) and used < bar_ticks:
            step, octave = pitches[cursor]
            remaining = bar_ticks - used if cursor == 14 else 240
            chunks = []
            while remaining:
                # A long final tonic (e.g. 12/8) may require tied written notes.
                duration, kind = next((d, t) for d, t in [(1920, "whole"), (960, "half"), (480, "quarter"), (240, "eighth")] if d <= remaining)
                chunks.append((duration, kind)); remaining -= duration
            for i, (duration, kind) in enumerate(chunks):
                note = build.child(bar, "note")
                pitch = build.child(note, "pitch")
                build.child(pitch, "step", step); build.child(pitch, "octave", octave)
                build.child(note, "duration", duration)
                ties = (["stop"] if i else []) + (["start"] if i < len(chunks) - 1 else [])
                for tie in ties:
                    build.child(note, "tie", type=tie)
                build.child(note, "type", kind)
                if ties:
                    notation = build.child(note, "notations")
                    for tie in ties:
                        build.child(notation, "tied", type=tie)
                used += duration
            cursor += 1
        assert used == bar_ticks
    assert cursor == 15
    return build.package(root), count


def append_naver(catalog, demo):
    import build_question_assets as build
    if not SOURCE.exists():
        return
    provenance = json.loads((SOURCE / "provenance.json").read_text(encoding="utf-8"))
    manifest_path = CONTENT / "engraving/manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for number in range(1, 60):
        filename = f"Q{number:03}.musicxml"
        source_bytes = (SOURCE / filename).read_bytes()
        info = provenance["questions"][filename]
        assert hashlib.sha256(source_bytes).hexdigest() == info["sha256"]
        source = ET.fromstring(source_bytes)
        original = source.find("part")
        numerator = int(original.findtext("measure/attributes/time/beats"))
        denominator = int(original.findtext("measure/attributes/time/beat-type"))
        divisions = int(original.findtext("measure/attributes/divisions"))
        title = f"고난도 청음 {number:02} · {numerator}/{denominator}"
        root, part = build.document(title, numerator, denominator)
        for index, source_bar in enumerate(original.findall("measure"), 1):
            bar = build.child(part, "measure", number=str(index))
            if index == 1:
                build.attributes(bar, numerator, denominator)
                # No key was inferred in the supplied transcription.
                bar.find("attributes/key/mode").text = "none"
            for source_note in source_bar.findall("note"):
                note = build.child(bar, "note")
                for item in source_note:
                    if item.tag in build.NOTE_TAGS:
                        note.append(copy.deepcopy(item))
                raw = int(note.findtext("duration")) * 480
                assert raw % divisions == 0
                note.find("duration").text = str(raw // divisions)
        assert len(part.findall("measure")) == 8
        main_bytes = build.package(root)
        scale_bytes, scale_measures = scale(numerator, denominator, build)
        target = CONTENT / "questions" / f"naver-{number:03}" / "v2"
        target.mkdir(parents=True, exist_ok=True)
        layout_id = f"staff-8bars-{numerator}-{denominator}-v2"
        layout_path = CONTENT / "sheets" / f"{layout_id}.layout.json"
        if not layout_path.exists():
            layout = copy.deepcopy(catalog[0]["metadata"]["sheet_layout"])
            layout.update(id=layout_id, template_png_url=f"https://api.sori.example/assets/sheets/{layout_id}.png")
            png = (CONTENT / "sheets" / f"{layout_id}.png").read_bytes()
            layout["template_sha256"] = hashlib.sha256(png).hexdigest()
            write_json(layout_path, layout)
        layout = json.loads(layout_path.read_text(encoding="utf-8"))
        png = (CONTENT / "sheets" / f"{layout_id}.png").read_bytes()
        (RESOURCES / f"{layout_id}.pngdata").write_bytes(png)
        question_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://sori.local/questions/naver-monophonic-{number:03}"))
        assets = {}
        for kind, data, measures in [("main", main_bytes, 8), ("scale", scale_bytes, scale_measures)]:
            (target / f"{kind}.mxl").write_bytes(data)
            # Keep the existing demo's catalog-order resource convention.
            (RESOURCES / f"excerpt-{number+3}-v2-{kind}.mxl").write_bytes(data)
            assets[kind] = {"url": f"https://api.sori.example/api/v1/questions/{question_id}/versions/2/scores/{kind}/", "content_type": "application/vnd.recordare.musicxml", "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data), "musicxml_version": "4.0", "profile": "sori-monophonic-v3", "part_id": "P1", "measure_count": measures, "source_tempo_bpm": build.TEMPO}
        metadata = {"id": question_id, "version": 2, "title": title, "source": "practice", "key_signature": {"tonic": "C", "mode": "unspecified", "fifths": 0}, "time_signature": {"numerator": numerator, "denominator": denominator}, "measure_count": 8, "recommended_duration_seconds": 300, "description": "임시표·셋잇단음표·당김음을 포함한 고난도 단성 청음입니다. 조표 없이 표기된 선율을 듣고 8마디를 적어보세요.", "time_policy": "advisory", "clef": "treble", "sheet_layout": layout, "content_policy": "client_readable_practice", "score_visibility": "after_submission", "score_assets": assets}
        catalog.append({"order": number+3, "metadata": metadata, "main_path": str((target / "main.mxl").relative_to(CONTENT)).replace("\\", "/"), "scale_path": str((target / "scale.mxl").relative_to(CONTENT)).replace("\\", "/")})
        demo.append(metadata)
        name = f"naver-{number:03}-reference-v1"
        data = (CONTENT / "engraving" / f"{name}.png").read_bytes()
        assert hashlib.sha256(data).hexdigest() == info["score_png_sha256"]
        width, height = struct.unpack(">II", data[16:24])
        (RESOURCES / f"{name}.pngdata").write_bytes(data)
        manifest["scores"][assets["main"]["sha256"]] = {"resource": name, "content_type": "image/png", "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data), "pixel_width": width, "pixel_height": height, "renderer": "Supplied final transcription / 2026-10-29"}
    write_json(manifest_path, manifest)
    write_json(RESOURCES / "engraving-manifest.json", manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    SOURCE.mkdir(parents=True, exist_ok=True)
    provenance = {"source_url": "https://blog.naver.com/smdpnp/222022610009", "revision": "final / 2026-10-29", "questions": {}}
    for number in range(1, 60):
        filename = f"Q{number:03}.musicxml"
        data = (args.source / "MusicXML" / filename).read_bytes()
        png = (args.source / "Scores" / f"Q{number:03}.png").read_bytes()
        score = ET.fromstring(data)
        status = score.findtext("identification/miscellaneous/miscellaneous-field[@name='status']")
        provenance["questions"][filename] = {"sha256": hashlib.sha256(data).hexdigest(), "score_png_sha256": hashlib.sha256(png).hexdigest(), "review_status": status}
        (SOURCE / filename).write_bytes(data)
        (CONTENT / "engraving" / f"naver-{number:03}-reference-v1.png").write_bytes(png)
    for filename in ("README_ko.md", "METER_METHOD.md"):
        shutil.copyfile(args.source / filename, SOURCE / filename)
    write_json(SOURCE / "provenance.json", provenance)
    import build_question_assets
    build_question_assets.main()


if __name__ == "__main__":
    main()
