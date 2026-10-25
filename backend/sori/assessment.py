"""Pure validation of model output; no database or provider dependency."""
import math

ANNOTATION_TYPES = ["pitch_error", "rhythm_error", "missing_note", "extra_note", "recognition_uncertain", "notation_error", "notation_suggestion"]
RESULT_SCHEMA = {"type": "object", "additionalProperties": False, "properties": {
    "status": {"type": "string", "enum": ["completed", "needs_review"]},
    "recognized_musicxml": {"type": "string"},
    "score": {"type": ["integer", "null"]},
    "pitch_accuracy": {"type": ["number", "null"]},
    "rhythm_accuracy": {"type": ["number", "null"]},
    "feedback": {"type": "object", "additionalProperties": False, "properties": {"summary": {"type": "string"}, "recommendations": {"type": "array", "items": {"type": "string"}}}, "required": ["summary", "recommendations"]},
    "annotations": {"type": "array", "items": {"type": "object", "additionalProperties": False, "properties": {"type": {"type": "string", "enum": ANNOTATION_TYPES}, "measure": {"type": ["integer", "null"]}, "note_index": {"type": ["integer", "null"], "minimum": 1, "maximum": 128}, "end_note_index": {"type": ["integer", "null"], "minimum": 1, "maximum": 128}, "message": {"type": "string"}}, "required": ["type", "measure", "note_index", "end_note_index", "message"]}},
}, "required": ["status", "recognized_musicxml", "score", "pitch_accuracy", "rhythm_accuracy", "feedback", "annotations"]}

def validate_result(value, layout):
    if not isinstance(value, dict) or set(value) != set(RESULT_SCHEMA["required"]) or value["status"] not in ("completed", "needs_review"):
        raise ValueError("invalid result shape")
    if not isinstance(value["recognized_musicxml"], str) or len(value["recognized_musicxml"]) > 500_000:
        raise ValueError("invalid recognition")
    for field in ("score", "pitch_accuracy", "rhythm_accuracy"):
        number = value[field]
        if value["status"] == "needs_review":
            if number is not None:
                raise ValueError("uncertain result has a score")
        elif type(number) not in (int, float) or not math.isfinite(number) or not 0 <= number <= 100 or (field == "score" and type(number) is not int):
            raise ValueError("invalid score")
    feedback = value["feedback"]
    if not isinstance(feedback, dict) or set(feedback) != {"summary", "recommendations"} or not isinstance(feedback["summary"], str) or not feedback["summary"].strip() or len(feedback["summary"]) > 10000 or not isinstance(feedback["recommendations"], list) or len(feedback["recommendations"]) > 20 or any(not isinstance(s, str) or len(s) > 3000 for s in feedback["recommendations"]):
        raise ValueError("invalid feedback")
    if not isinstance(value["annotations"], list) or len(value["annotations"]) > 100:
        raise ValueError("invalid annotations")
    annotations = []
    for index, item in enumerate(value["annotations"]):
        if not isinstance(item, dict) or not {"type", "measure", "message"} <= set(item) or set(item) - {"type", "measure", "message", "note_index", "end_note_index"} or item["type"] not in ANNOTATION_TYPES or not isinstance(item["message"], str) or len(item["message"]) > 3000:
            raise ValueError("invalid annotation")
        note, end = item.get("note_index"), item.get("end_note_index")
        if (note is not None and (type(note) is not int or not 1 <= note <= 128)) or (end is not None and (type(end) is not int or note is None or not note <= end <= 128)) or (note is not None and item["measure"] is None):
            raise ValueError("invalid note location")
        measure, box = item["measure"], None
        if measure is not None:
            if type(measure) is not int or not 1 <= measure <= 8:
                raise ValueError("invalid measure")
            system = next(s for s in layout["systems"] if s["first_measure"] <= measure <= s["last_measure"])
            position = measure - system["first_measure"]
            left, right = system["barline_x"][position:position + 2]
            top = max(0, system["staff_line_y"][0] - 90)
            bottom = min(layout["logical_height"], system["staff_line_y"][-1] + 90)
            box = {"x": left / layout["logical_width"], "y": top / layout["logical_height"], "width": (right - left) / layout["logical_width"], "height": (bottom - top) / layout["logical_height"]}
        annotations.append({"id": f"ai-{index + 1}", **item, "bbox": box})
    value["annotations"] = annotations
    return value
