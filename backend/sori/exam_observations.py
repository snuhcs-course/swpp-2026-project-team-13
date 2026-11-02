"""Keep AI error evidence without treating it as a confirmed skill diagnosis."""
import copy
import xml.etree.ElementTree as ET
from .features.musicxml import FeatureError, parse_xml

ERROR_TYPES = {"pitch_error", "rhythm_error", "missing_note", "extra_note", "notation_error"}


def build_error_observations(result, feature_analysis_id=None):
    if result.get("status") != "completed":
        return []
    annotations = result.get("annotations", [])
    errors = [a for a in annotations if a.get("type") in ERROR_TYPES]
    if not errors:
        return []
    measures, reason = {}, "invalid_recognized_musicxml"
    try:
        root = parse_xml(result.get("recognized_musicxml", "").encode("utf-8"))
        parts = root.findall("part")
        if root.tag == "score-partwise" and len(parts) == 1:
            attributes = {}
            for index, measure in enumerate(parts[0].findall("measure"), 1):
                for block in measure.findall("attributes"):
                    for child in block:
                        attributes[child.tag] = copy.deepcopy(child)
                context = ET.Element("attributes")
                context.extend(copy.deepcopy(list(attributes.values())))
                measures[index] = (ET.tostring(measure, encoding="unicode"), ET.tostring(context, encoding="unicode"))
            reason = "recognized_measure_missing"
    except FeatureError:
        pass
    result_rows = []
    for annotation in errors:
        number = annotation.get("measure")
        evidence = measures.get(number)
        uncertain = any(a.get("type") == "recognition_uncertain" and (a.get("measure") is None or a.get("measure") == number) for a in annotations)
        result_rows.append({
            "source": "ai", "annotation_id": annotation.get("id"), "error_type": annotation["type"],
            "measure": number, "note_index": annotation.get("note_index"), "end_note_index": annotation.get("end_note_index"),
            "feature_analysis_id": str(feature_analysis_id) if feature_analysis_id else None,
            "evidence_scope": "measure" if number is not None else "unlocated", "recognition_uncertain": uncertain,
            "xml_format": "musicxml_measure_fragment", "xml_status": "captured" if evidence else "unavailable",
            "measure_musicxml": evidence[0] if evidence else None, "context_musicxml": evidence[1] if evidence else None,
            "unavailable_reason": None if evidence else "missing_measure_location" if number is None else reason,
        })
    return result_rows
