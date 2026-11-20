"""Reference coordinates come from the published engraving, never the model."""
import json
import hashlib
from functools import lru_cache
from django.conf import settings
from .engraving import reference_asset


@lru_cache(maxsize=1)
def note_map():
    path = settings.CONTENT_ROOT / "engraving/exam-note-map-v1.json"
    try:
        raw = path.read_bytes()
        manifest = json.loads(path.with_name("exam-note-map-manifest-v1.json").read_text(encoding="utf-8"))
        if hashlib.sha256(raw).hexdigest() != manifest["sha256"]: return {}
        return json.loads(raw)["assets"]
    except (OSError, ValueError, KeyError, TypeError):
        # Optional geometry may fall back to measure marks without breaking grading.
        return {}


def reference_marks(job):
    if job.status != "completed" or not job.annotations: return []
    q = job.attempt.question_snapshot
    if "score_assets" not in q: return []
    asset = reference_asset(q)
    if not asset or not asset.get("geometry"): return []
    geometry = asset["geometry"]; result = []
    verified = note_map().get(asset["sha256"], {})
    if verified.get("main_sha256") != q["score_assets"]["main"]["sha256"]: verified = {}
    glyph_budget = 256
    for annotation in job.annotations:
        measure = annotation.get("measure")
        if type(measure) is not int or not 1 <= measure <= 8 or annotation["type"] in ("notation_suggestion", "recognition_uncertain"): continue
        system = next(s for s in geometry["systems"] if s["first_measure"] <= measure <= s["last_measure"])
        i = measure-system["first_measure"]; left, right = system["barline_x"][i:i+2]
        w, h = geometry["logical_width"], geometry["logical_height"]
        box = {"x": left/w, "y": max(0, system["staff_line_y"][0]-60)/h,
               "width": (right-left)/w, "height": (system["staff_line_y"][-1]-system["staff_line_y"][0]+120)/h}
        marks = verified.get("measures", {}).get(str(measure), [])
        first = annotation.get("note_index"); last = annotation.get("end_note_index") or first
        precise = job.grading_version == "ai-melodic-v3" and annotation["type"] != "extra_note" and type(first) is int and type(last) is int and 1 <= first <= last <= len(marks) and last-first+1 <= glyph_budget
        selected = marks[first-1:last] if precise else []
        glyph_budget -= len(selected)
        style = "underline" if precise and annotation["type"] in ("rhythm_error", "notation_error") else "glyph" if precise else "measure"
        result.append({"id": annotation["id"], "measure": measure, "style": style, "message": annotation["message"],
            "bbox": box, "glyphs": [{"bbox": m["bbox"], "commands": m["commands"]} for m in selected]})
    return result
