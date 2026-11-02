"""Bounded MusicXML reader. No Django, network, audio inference or key guessing."""
import zipfile
from fractions import Fraction as F
from pathlib import Path, PurePosixPath
import xml.etree.ElementTree as ET

MAX_XML_BYTES = 2_000_000
STEPS = dict(C=0, D=2, E=4, F=5, G=7, A=9, B=11)
LETTERS = "CDEFGAB"
TYPES = {"whole": F(4), "half": F(2), "quarter": F(1), "eighth": F(1, 2),
         "16th": F(1, 4), "32nd": F(1, 8), "64th": F(1, 16), "128th": F(1, 32)}
PULSES = {"2/4": F(1), "3/4": F(1), "4/4": F(1), "6/8": F(3, 2),
          "9/8": F(3, 2), "12/8": F(3, 2)}
GROUPS = {"2/4": [1, 1], "3/4": [1, 1, 1], "4/4": [1, 1, 1, 1],
          "6/8": [3, 3], "9/8": [3, 3, 3], "12/8": [3, 3, 3, 3]}


class FeatureError(ValueError):
    def __init__(self, code, *, measure=None):
        self.code, self.measure = code, measure
        super().__init__(code + (f" at measure {measure}" if measure else ""))


def parse_xml(raw):
    if len(raw) > MAX_XML_BYTES:
        raise FeatureError("xml_too_large")
    # Also reject entity declarations in UTF-16/32 documents. External DTDs are
    # never fetched by ElementTree; common MusicXML DOCTYPE declarations are OK.
    if b"<!ENTITY" in raw.replace(b"\x00", b"").upper():
        raise FeatureError("entity_declaration_not_allowed")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise FeatureError("invalid_xml") from error
    for node in root.iter():
        node.tag = node.tag.split("}")[-1]
    return root


def read_xml(path):
    path = Path(path)
    if path.suffix.lower() not in (".mxl", ".xml", ".musicxml"):
        raise FeatureError("unsupported_file_type")
    if path.suffix.lower() != ".mxl":
        with path.open("rb") as source:
            raw = source.read(MAX_XML_BYTES + 1)
        parse_xml(raw)
        return raw
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if len(infos) > 1024 or len({x.filename for x in infos}) != len(infos):
                raise FeatureError("invalid_mxl_entries")

            def read_member(name):
                if "\\" in name or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
                    raise FeatureError("invalid_mxl_path")
                info = archive.getinfo(name)
                if info.file_size > MAX_XML_BYTES:
                    raise FeatureError("xml_too_large")
                with archive.open(info) as source:
                    raw = source.read(MAX_XML_BYTES + 1)
                if len(raw) > MAX_XML_BYTES:
                    raise FeatureError("xml_too_large")
                return raw

            container = parse_xml(read_member("META-INF/container.xml"))
            roots = container.findall("rootfiles/rootfile")
            target = next((x.get("full-path") for x in roots
                           if x.get("media-type") == "application/vnd.recordare.musicxml+xml"), None)
            target = target or (roots[0].get("full-path") if roots else None)
            if not target:
                raise FeatureError("missing_mxl_rootfile")
            raw = read_member(target)
            parse_xml(raw)
            return raw
    except (zipfile.BadZipFile, KeyError, RuntimeError, NotImplementedError) as error:
        raise FeatureError("invalid_mxl") from error


def number(value, code, measure, *, positive=False, integral=False):
    try:
        result = F(value)
    except (ValueError, TypeError, ZeroDivisionError) as error:
        raise FeatureError(code, measure=measure) from error
    if (positive and result <= 0) or (integral and result.denominator != 1):
        raise FeatureError(code, measure=measure)
    return int(result) if integral else result


def decode(raw, question_id, groupings):
    root = parse_xml(raw)
    if root.tag != "score-partwise":
        raise FeatureError("requires_score_partwise")
    parts = root.findall("part")
    if len(parts) != 1:
        raise FeatureError("requires_one_part")
    events, attacks, measures, diagnostics = [], [], [], []
    divisions = meter = key = voice = staff = None
    absolute, opened = F(0), None
    for mi, node in enumerate(parts[0].findall("measure"), 1):
        offset = F(0)
        attrs = node.findall("attributes")
        children = list(node)
        first_note = next((i for i, n in enumerate(children) if n.tag == "note"), len(children))
        if len(attrs) > 1 or any(i > first_note for i, n in enumerate(children) if n.tag == "attributes"):
            raise FeatureError("mid_measure_attributes_not_supported", measure=mi)
        if node.find("backup") is not None or node.find("forward") is not None:
            raise FeatureError("backup_or_forward_not_supported", measure=mi)
        if attrs:
            attr = attrs[0]
            if attr.find("transpose") is not None:
                raise FeatureError("transposing_instrument_not_supported", measure=mi)
            if attr.find("staves") is not None and attr.findtext("staves") != "1":
                raise FeatureError("requires_one_staff", measure=mi)
            if attr.find("divisions") is not None:
                divisions = number(attr.findtext("divisions"), "invalid_divisions", mi, positive=True)
            if attr.find("time") is not None:
                time = attr.find("time")
                if len(time.findall("beats")) != 1 or len(time.findall("beat-type")) != 1:
                    raise FeatureError("unsupported_time_signature", measure=mi)
                beats = number(time.findtext("beats"), "invalid_meter", mi, positive=True, integral=True)
                unit = number(time.findtext("beat-type"), "invalid_meter", mi, positive=True, integral=True)
                meter = f"{beats}/{unit}"
            if attr.find("key") is not None:
                kn = attr.find("key")
                if kn.find("key-step") is not None or kn.find("fifths") is None:
                    raise FeatureError("nontraditional_key_not_supported", measure=mi)
                fifths = number(kn.findtext("fifths"), "invalid_key", mi, integral=True)
                if not -7 <= fifths <= 7:
                    raise FeatureError("unsupported_key_signature", measure=mi)
                key = dict(fifths=fifths, mode=kn.findtext("mode", "unknown"))
        if divisions is None or meter is None:
            raise FeatureError("missing_divisions_or_meter", measure=mi)
        beats, unit = map(int, meter.split("/"))
        expected = F(4 * beats, unit)
        grouping = groupings.get(str(mi), GROUPS.get(meter))
        if grouping is not None:
            if not isinstance(grouping, list) or any(type(x) is not int or x <= 0 for x in grouping) or sum(grouping) != beats:
                raise FeatureError("invalid_beat_grouping", measure=mi)
            if meter in GROUPS and grouping != GROUPS[meter]:
                raise FeatureError("unsupported_beat_grouping", measure=mi)
        pulse = PULSES.get(meter)
        event_ids = []
        for ni, n in enumerate(node.findall("note"), 1):
            if n.find("chord") is not None or n.find("grace") is not None:
                raise FeatureError("chord_or_grace_not_supported", measure=mi)
            nv, ns = n.findtext("voice", "1"), n.findtext("staff", "1")
            voice, staff = voice or nv, staff or ns
            if voice != nv or staff != ns:
                raise FeatureError("multiple_voices_or_staves", measure=mi)
            duration = number(n.findtext("duration"), "invalid_duration", mi, positive=True) / divisions
            typ, dots = n.findtext("type"), len(n.findall("dot"))
            if dots > 8:
                raise FeatureError("unsupported_dot_count", measure=mi)
            tm = n.find("time-modification")
            ratio = [number(tm.findtext("actual-notes"), "invalid_tuplet", mi, positive=True, integral=True),
                     number(tm.findtext("normal-notes"), "invalid_tuplet", mi, positive=True, integral=True)] if tm is not None else [1, 1]
            rest = n.find("rest") is not None
            full_rest = rest and n.find("rest").get("measure") == "yes"
            if full_rest:
                if duration != expected:
                    raise FeatureError("measure_rest_duration_mismatch", measure=mi)
            elif typ is None:
                diagnostics.append(dict(code="missing_note_type", measure=mi, index=ni))
            elif typ not in TYPES:
                raise FeatureError("unsupported_note_type", measure=mi)
            elif duration != TYPES[typ] * sum((F(1, 2**i) for i in range(dots + 1)), F(0)) * F(ratio[1], ratio[0]):
                raise FeatureError("notated_duration_mismatch", measure=mi)
            ties = n.findall("tie")
            if any(t.get("time-only") is not None for t in ties):
                raise FeatureError("conditional_tie_not_supported", measure=mi)
            types = [t.get("type") for t in ties]
            if len(set(types)) != len(types) or any(t not in ("start", "stop") for t in types):
                raise FeatureError("invalid_tie", measure=mi)
            e = dict(id=f"{question_id}:m{mi}:n{ni}", measure=mi, index=ni, onset_qn=str(offset),
                     absolute_onset_qn=str(absolute + offset), duration_qn=str(duration),
                     kind="rest" if rest else "note", step=None, alter=None, octave=None, midi=None,
                     type=typ, dots=dots, tuplet_ratio=ratio, accidental=None,
                     beams=[dict(number=b.get("number", "1"), value=b.text) for b in n.findall("beam")],
                     tie_start="start" in types, tie_stop="stop" in types, attack_id=None)
            if rest:
                if opened is not None or types:
                    raise FeatureError("tie_interrupted_by_rest", measure=mi)
            else:
                step = n.findtext("pitch/step")
                if step not in STEPS:
                    raise FeatureError("unsupported_pitch", measure=mi)
                octave = number(n.findtext("pitch/octave"), "invalid_octave", mi, integral=True)
                alter = number(n.findtext("pitch/alter", "0"), "microtone_not_supported", mi, integral=True)
                midi = (octave + 1) * 12 + STEPS[step] + alter
                if not 0 <= midi <= 127:
                    raise FeatureError("pitch_out_of_range", measure=mi)
                e.update(step=step, alter=alter, octave=octave, midi=midi)
                acc = n.find("accidental")
                if acc is not None:
                    e["accidental"] = dict(symbol=acc.text, cautionary=acc.get("cautionary") == "yes",
                                           editorial=acc.get("editorial") == "yes")
                if e["tie_stop"]:
                    if opened is None or opened["midi"] != midi or F(opened["absolute_onset_qn"]) + F(opened["sounding_duration_qn"]) != absolute + offset:
                        raise FeatureError("broken_tie", measure=mi)
                    attack = opened
                    attack["sounding_duration_qn"] = str(F(attack["sounding_duration_qn"]) + duration)
                    attack["member_event_ids"].append(e["id"])
                else:
                    if opened is not None:
                        raise FeatureError("missing_tie_stop", measure=mi)
                    attack = dict(id=e["id"], member_event_ids=[e["id"]], onset_qn=str(offset),
                                  absolute_onset_qn=str(absolute + offset), sounding_duration_qn=str(duration), midi=midi)
                    attacks.append(attack)
                e["attack_id"] = attack["id"]
                opened = attack if e["tie_start"] else None
            events.append(e)
            event_ids.append(e["id"])
            offset += duration
        if offset > expected:
            raise FeatureError("overfull_measure", measure=mi)
        if offset != expected:
            diagnostics.append(dict(code="incomplete_measure", measure=mi))
        if node.find("barline/repeat") is not None:
            diagnostics.append(dict(code="repeat_not_expanded", measure=mi))
        measures.append(dict(number=mi, written_number=node.get("number"), meter=meter,
                             beat_grouping=grouping, pulse_qn=str(pulse) if pulse else None,
                             key_signature=dict(key) if key else None, actual_duration_qn=str(offset),
                             expected_duration_qn=str(expected), event_ids=event_ids))
        absolute += offset
    if opened is not None:
        raise FeatureError("unfinished_tie")
    if not attacks:
        raise FeatureError("no_pitched_attacks")
    unknown_groupings = set(groupings) - {str(m["number"]) for m in measures}
    if unknown_groupings:
        raise FeatureError("beat_grouping_measure_not_found")
    return measures, events, attacks, diagnostics
