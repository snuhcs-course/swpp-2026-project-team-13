"""Feature v1 behavioral tests; runnable with the Python standard library."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from .features import FeatureError, analyze, analyze_bytes, read_xml, select_span

BACKEND_DIR = Path(__file__).resolve().parents[1]
ROOT = BACKEND_DIR.parent
FIXTURE = Path(__file__).parent / "features/fixtures/example.musicxml"


def note(step="C", duration=1, typ="quarter", extra="", alter=0, octave=4):
    pitch = f"<pitch><step>{step}</step><alter>{alter}</alter><octave>{octave}</octave></pitch>" if step else "<rest/>"
    return f"<note>{pitch}<duration>{duration}</duration><type>{typ}</type>{extra}</note>"


def score(bars, meter=(4, 4), fifths=0, divisions=1):
    key = "" if fifths is None else f"<key><fifths>{fifths}</fifths></key>"
    attrs = f"<attributes><divisions>{divisions}</divisions>{key}<time><beats>{meter[0]}</beats><beat-type>{meter[1]}</beat-type></time></attributes>"
    return ("<score-partwise><part-list/><part id='P1'>" + "".join(
        f"<measure number='{i}'>{attrs if i == 1 else ''}{bar}</measure>" for i, bar in enumerate(bars, 1)
    ) + "</part></score-partwise>").encode()


class FeatureTests(unittest.TestCase):
    def analyze(self, raw, **kwargs):
        return analyze_bytes(raw, question_id="test", **kwargs)

    def test_specification_fixture_has_expected_boundary_and_repeat(self):
        r = analyze(FIXTURE, question_id="fixture-v1")
        self.assertEqual(r["analysis_status"], "complete")
        m = r["metrics"]
        self.assertEqual((m["attack_count"], m["interval_count"]), (8, 7))
        self.assertEqual((m["large_up_count"], m["large_down_count"]), (1, 1))
        self.assertEqual(m["mean_abs_semitones"], 25 / 7)
        self.assertEqual(m["exact_rhythm_repeat_fraction"], .5)
        self.assertEqual(r["measures"][1]["metrics"]["large_down_count"], 0)
        doc = ROOT / "docs/feature-v1/example.json"
        if doc.exists():
            expected = json.loads(doc.read_text(encoding="utf-8"))
            for field, value in expected["metrics"].items():
                self.assertEqual(m[field], value, field)

    def test_perfect_diminished_fifth_and_augmented_fourth_are_distinct(self):
        for step, alter, generic, semis, large in (("G", 0, 5, 7, 1), ("G", -1, 5, 6, 1), ("F", 1, 4, 6, 0)):
            with self.subTest(step=step, alter=alter):
                r = self.analyze(score([note() + note(step, alter=alter) + note(step, alter=alter) * 2]))
                iv = r["intervals"][0]
                self.assertEqual((iv["generic"], iv["semitones"]), (generic, semis))
                self.assertEqual(r["metrics"]["large_up_count"], large)

    def test_span_excludes_incoming_and_outgoing_leaps(self):
        r = self.analyze(score([note("G") * 4, note() * 4, note("G") * 4]))
        original = copy.deepcopy(r)
        self.assertEqual(select_span(r, 2, 2)["metrics"]["large_down_count"], 0)
        self.assertEqual(select_span(r, 1, 2)["metrics"]["large_down_count"], 1)
        self.assertEqual(select_span(r, 2, 3)["metrics"]["large_up_count"], 1)
        self.assertEqual(select_span(r, 2, 3)["metrics"]["large_down_count"], 0)
        self.assertEqual(r, original)
        self.assertEqual(next(f["scope"] for f in select_span(r, 1, 2)["features"] if f["code"] == "large_down"), "connection")

    def test_repeat_relationship_is_rebased_to_selected_span(self):
        r = self.analyze(score([note() * 4, note("G") * 4, note("D") * 4]))
        self.assertFalse(any(f["code"] == "exact_rhythm_repeat" for f in select_span(r, 2, 2)["features"]))
        repeats = [f for f in select_span(r, 2, 3)["features"] if f["code"] == "exact_rhythm_repeat"]
        self.assertEqual(len(repeats), 1)
        self.assertEqual(repeats[0]["measure_ids"], [2, 3])
        self.assertEqual(repeats[0]["details"]["first_measure"], 2)

    def test_tie_preserves_notation_but_counts_one_attack_and_chain(self):
        r = self.analyze(score([note(duration=4, typ="whole", extra='<tie type="start"/>'), note(duration=4, typ="whole", extra='<tie type="stop"/>')]))
        self.assertEqual((r["metrics"]["written_note_count"], r["metrics"]["attack_count"], r["metrics"]["tie_chain_count"]), (2, 1, 1))
        self.assertEqual(r["attacks"][0]["sounding_duration_qn"], "8")
        self.assertIsNone(r["metrics"]["mean_abs_semitones"])
        for first in (1, 2):
            view = select_span(r, first, first)
            self.assertEqual(view["standalone_status"], "requires_tie_adaptation")
            self.assertEqual(view["metrics"]["tie_chain_count"], 0)
        self.assertEqual(select_span(r, 2, 2)["metrics"]["attack_count"], 0)
        self.assertEqual(select_span(r, 1, 2)["standalone_status"], "ready")

    def test_internal_tie_split_does_not_change_audible_duration(self):
        a = self.analyze(score([note(duration=4, typ="whole")]))
        b = self.analyze(score([note(duration=2, typ="half", extra='<tie type="start"/>') + note(duration=2, typ="half", extra='<tie type="stop"/>')]))
        self.assertEqual(a["attacks"][0]["sounding_duration_qn"], b["attacks"][0]["sounding_duration_qn"])
        self.assertEqual(a["metrics"]["attack_count"], b["metrics"]["attack_count"])
        self.assertNotEqual(a["measures"][0]["rhythm_pattern_id"], b["measures"][0]["rhythm_pattern_id"])

    def test_short_attack_uses_combined_sound_not_first_written_segment(self):
        r = self.analyze(score([note(duration=1, typ="16th", extra='<tie type="start"/>') +
                                note(duration=3, typ="eighth", extra='<dot/><tie type="stop"/>') +
                                note(duration=4) * 3], divisions=4))
        self.assertEqual(r["metrics"]["short_sounding_attack_count"], 0)

    def test_six_eighths_have_two_analytical_pulses(self):
        r = self.analyze(score([note(duration=1, typ="eighth") * 6], meter=(6, 8), divisions=2))
        self.assertEqual(r["measures"][0]["pulse_qn"], "3/2")
        self.assertEqual(r["metrics"]["duration_pulses"], "2")
        self.assertEqual(r["metrics"]["attacks_per_pulse"], 3)

    def test_all_supported_meters_use_the_documented_pulses(self):
        for beats, unit, pulses in ((2, 4, 2), (3, 4, 3), (4, 4, 4), (6, 8, 2), (9, 8, 3), (12, 8, 4)):
            with self.subTest(meter=(beats, unit)):
                compound = unit == 8
                r = self.analyze(score([note(typ="eighth" if compound else "quarter") * beats],
                                       meter=(beats, unit), divisions=2 if compound else 1))
                self.assertEqual(r["metrics"]["duration_pulses"], str(pulses))
                self.assertEqual(r["metrics"]["attacks_per_pulse"], 3 if compound else 1)

    def test_tuplet_rest_is_counted_and_time_remains_exact(self):
        tm = '<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>'
        r = self.analyze(score([note(None, typ="eighth", extra=tm) + note(typ="eighth", extra=tm) * 2 + note(duration=3) * 3], divisions=3))
        self.assertEqual(r["events"][0]["duration_qn"], "1/3")
        self.assertEqual(r["metrics"]["tuplet_event_count"], 3)
        self.assertEqual(r["metrics"]["tuplet_attack_share"], 2 / 5)
        self.assertNotIn("tuplet_group_count", r["metrics"])

    def test_dotted_rest_and_note_each_count_once(self):
        r = self.analyze(score([note(None, duration=3, extra="<dot/>") + note(duration=3, extra="<dot/>")], meter=(3, 4), divisions=2))
        self.assertEqual(r["metrics"]["dotted_event_count"], 2)

    def test_missing_key_is_unknown_without_changing_pitch(self):
        r = self.analyze(score([note("F", alter=1, extra="<accidental>sharp</accidental>") * 4], fifths=None))
        self.assertEqual(r["events"][0]["midi"], 66)
        self.assertIsNone(r["metrics"]["key_relative_alteration_count"])
        self.assertEqual(r["metrics"]["explicit_accidental_count"], 4)
        self.assertEqual(r["unavailable_reasons"]["metrics.key_relative_alteration_count"], ["missing_key_signature"])
        self.assertEqual(r["analysis_status"], "partial")

    def test_pitch_alter_is_not_added_to_key_or_display_accidental(self):
        r = self.analyze(score([note("F", alter=1) * 4], fifths=1))
        self.assertEqual(r["events"][0]["midi"], 66)
        self.assertEqual(r["metrics"]["key_relative_alteration_count"], 0)
        r = self.analyze(score([note("F", alter=0, extra="<accidental>natural</accidental>") * 4], fifths=1))
        self.assertEqual(r["events"][0]["midi"], 65)
        self.assertEqual(r["metrics"]["key_relative_alteration_count"], 4)

    def test_cautionary_and_editorial_are_separate(self):
        r = self.analyze(score([note(extra='<accidental cautionary="yes">natural</accidental>') +
                                note(extra='<accidental editorial="yes">natural</accidental>') + note() * 2]))
        self.assertEqual(r["metrics"]["explicit_accidental_count"], 2)
        self.assertEqual(r["metrics"]["cautionary_accidental_count"], 1)
        self.assertEqual(r["metrics"]["editorial_accidental_count"], 1)
        self.assertEqual(r["metrics"]["key_relative_alteration_count"], 0)

    def test_rest_crossing_is_recorded_and_filter_changes_identity(self):
        raw = score([note() + note(None) + note("G") + note()])
        a = self.analyze(raw)
        b = self.analyze(raw, config={"intervals_across_rests": False})
        self.assertTrue(a["intervals"][0]["across_rest"])
        self.assertEqual((a["metrics"]["interval_count"], b["metrics"]["interval_count"]), (2, 1))
        self.assertNotEqual(a["analysis_key"], b["analysis_key"])

    def test_offbeat_sustain_is_one_candidate_and_exact_end_is_excluded(self):
        a = self.analyze(score([note(duration=1, typ="eighth") + note(duration=3, extra="<dot/>") + note(duration=4, typ="half")], divisions=2))
        self.assertEqual(a["metrics"]["offbeat_sustain_candidate_count"], 1)
        f = next(f for f in a["features"] if f["code"] == "offbeat_sustain_candidate")
        self.assertEqual((f["kind"], f["details"]["crossed_onset_qn"]), ("candidate", "1"))
        b = self.analyze(score([note(duration=1, typ="eighth") * 2 + note(duration=2) * 3], divisions=2))
        self.assertEqual(b["metrics"]["offbeat_sustain_candidate_count"], 0)

    def test_beam_crossing_counts_group_once(self):
        values = ("begin", "continue", "continue", "end")
        raw = score(["".join(note(duration=1, typ="eighth", extra=f'<beam number="1">{v}</beam>') for v in values) + note(duration=4, typ="half")], divisions=2)
        r = self.analyze(raw)
        self.assertEqual(r["metrics"]["cross_pulse_beam_candidate_count"], 1)
        f = next(f for f in r["features"] if f["code"] == "cross_pulse_beam_candidate")
        self.assertEqual(len(f["event_ids"]), 4)

    def test_incomplete_beam_is_unknown_not_zero(self):
        r = self.analyze(score([note(extra='<beam number="1">begin</beam>') + note() * 3]))
        self.assertIsNone(r["metrics"]["cross_pulse_beam_candidate_count"])
        self.assertEqual(r["analysis_status"], "partial")

    def test_sustain_over_a_meter_change_is_withheld(self):
        first = note(duration=2) * 3 + note(duration=1, typ="eighth") + note(duration=1, typ="eighth", extra='<tie type="start"/>')
        second = '<attributes><time><beats>3</beats><beat-type>4</beat-type></time></attributes>' + note(duration=2, extra='<tie type="stop"/>') + note(duration=2) * 2
        r = self.analyze(score([first, second], divisions=2))
        self.assertIsNone(r["metrics"]["offbeat_sustain_candidate_count"])
        self.assertIn("meter_boundary_not_supported", r["unavailable_reasons"]["metrics.offbeat_sustain_candidate_count"])

    def test_candidate_tie_evidence_covers_both_measures(self):
        first = note(duration=2) * 3 + note(duration=1, typ="eighth") + note(duration=1, typ="eighth", extra='<tie type="start"/>')
        second = note(duration=2, extra='<tie type="stop"/>') + note(duration=2) * 3
        r = self.analyze(score([first, second], divisions=2))
        candidate = next(f for f in r["features"] if f["code"] == "offbeat_sustain_candidate")
        self.assertEqual(candidate["scope"], "connection")
        self.assertEqual(candidate["measure_ids"], [1, 2])
        self.assertEqual(select_span(r, 2, 2)["metrics"]["offbeat_sustain_candidate_count"], 0)

    def test_pattern_ignores_pitch_and_beam_but_preserves_rest(self):
        a = self.analyze(score([note() * 4, note("G") * 4]))
        b = self.analyze(score([note() * 4, note(None) + note("G") * 3]))
        self.assertEqual(a["measures"][0]["rhythm_pattern_id"], a["measures"][1]["rhythm_pattern_id"])
        self.assertNotEqual(b["measures"][0]["rhythm_pattern_id"], b["measures"][1]["rhythm_pattern_id"])
        self.assertEqual(len(a["measures"][0]["rhythm_pattern_id"]), 64)

    def test_seven_eighths_keeps_notes_and_withholds_pulse_features(self):
        raw = score([note(typ="eighth") * 7], meter=(7, 8), divisions=2)
        a = self.analyze(raw)
        self.assertEqual(a["metrics"]["attack_count"], 7)
        self.assertIsNone(a["metrics"]["attacks_per_pulse"])
        self.assertIn("needs_beat_grouping", a["unavailable_reasons"]["metrics.duration_pulses"])
        b = self.analyze(raw, config={"beat_groupings": {"1": [2, 2, 3]}})
        self.assertEqual(b["measures"][0]["beat_grouping"], [2, 2, 3])
        self.assertIsNone(b["metrics"]["attacks_per_pulse"])

    def test_other_unsupported_meter_does_not_guess_pulse(self):
        r = self.analyze(score([note() * 4], meter=(2, 2)))
        self.assertIsNone(r["metrics"]["duration_pulses"])
        self.assertEqual(r["unavailable_reasons"]["metrics.duration_pulses"], ["unsupported_meter"])

    def test_pickup_duration_is_not_padded(self):
        r = self.analyze(score([note(), note() * 4]))
        self.assertEqual(r["measures"][0]["actual_duration_qn"], "1")
        self.assertEqual(r["events"][1]["absolute_onset_qn"], "1")
        self.assertIsNone(r["measures"][0]["metrics"]["offbeat_sustain_candidate_count"])

    def test_rest_only_span_and_single_note_have_null_pitch_statistics(self):
        r = self.analyze(score([note(duration=4, typ="whole"), note(None, duration=4, typ="whole")]))
        view = select_span(r, 2, 2)
        self.assertEqual(view["metrics"]["attack_count"], 0)
        self.assertIsNone(view["metrics"]["pitch_range_semitones"])
        self.assertIsNone(r["metrics"]["mean_abs_semitones"])
        self.assertEqual(r["analysis_status"], "complete")

    def test_serialization_is_deterministic_and_does_not_mutate_config(self):
        raw = score([note() * 4])
        config = {"missing_key_policy": "unknown", "intervals_across_rests": True}
        original = copy.deepcopy(config)
        a, b = self.analyze(raw), self.analyze(raw, config=config)
        self.assertEqual(a, b)
        self.assertEqual(config, original)
        self.assertEqual(json.loads(json.dumps(a, allow_nan=False)), a)
        c = self.analyze(raw, question_version=2)
        self.assertNotEqual(a["analysis_key"], c["analysis_key"])

    def test_source_review_does_not_invent_validation(self):
        r = self.analyze(score([note() * 4]))
        self.assertEqual(r["source_review"]["status"], "unreviewed")
        self.assertEqual(r["analysis_status"], "complete")
        self.assertEqual(r["experimental"], {})

    def test_invalid_config_and_spans_are_rejected(self):
        raw = score([note() * 4])
        for config in (False, {"unexpected": 1}, {"missing_key_policy": "C major"}, {"intervals_across_rests": 1}, {"beat_groupings": {"01": [1, 1, 1, 1]}}, {"beat_groupings": {"2": [1, 1, 1, 1]}}):
            with self.subTest(config=config), self.assertRaises(FeatureError):
                self.analyze(raw, config=config)
        r = self.analyze(raw)
        for first, last in ((0, 1), (1, 2), (True, 1), (1, 0)):
            with self.assertRaisesRegex(FeatureError, "invalid_span"):
                select_span(r, first, last)

    def test_invalid_music_is_rejected_with_reason(self):
        cases = [
            (score([note(duration=2) + note() * 2]), "notated_duration_mismatch"),
            (score([note(extra='<tie type="stop"/>') + note() * 3]), "broken_tie"),
            (score([note(extra='<tie type="start"/>') + note() * 3]), "missing_tie_stop"),
            (score([note() * 5]), "overfull_measure"),
            (score([note() + '<backup><duration>1</duration></backup>']), "backup_or_forward_not_supported"),
            (score([note(extra="<chord/>") + note() * 3]), "chord_or_grace_not_supported"),
            (score([note(extra="<voice>2</voice>") + note() * 3]), "multiple_voices_or_staves"),
            (score([note(alter="0.5") * 4]), "microtone_not_supported"),
            (score([note(extra='<tie type="start" time-only="1"/>') + note() * 3]), "conditional_tie_not_supported"),
            (b'<!DOCTYPE x [<!ENTITY x "bad">]><score-partwise/>', "entity_declaration_not_allowed"),
            (score([note(None, duration=4, typ="whole")]), "no_pitched_attacks"),
        ]
        for raw, code in cases:
            with self.subTest(code=code), self.assertRaisesRegex(FeatureError, code):
                self.analyze(raw)

    def test_mid_measure_attribute_change_is_rejected(self):
        raw = score([note() + "<attributes><divisions>2</divisions></attributes>" + note() * 3])
        with self.assertRaisesRegex(FeatureError, "mid_measure_attributes"):
            self.analyze(raw)

    def test_external_doctype_is_not_fetched_and_entities_are_rejected(self):
        raw = b'<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "https://example.invalid/musicxml.dtd">' + score([note() * 4])
        self.assertEqual(self.analyze(raw)["metrics"]["attack_count"], 4)
        entity = '<!DOCTYPE x [<!ENTITY x "bad">]><score-partwise/>'.encode('utf-16')
        with self.assertRaisesRegex(FeatureError, "entity_declaration_not_allowed"):
            self.analyze(entity)

    def test_mxl_rootfile_and_namespace_are_respected(self):
        directory = BACKEND_DIR / ".tmp/feature-tests"
        directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=directory) as temporary:
            self.assertTrue(Path(temporary).resolve().is_relative_to(directory.resolve()))
            path = Path(temporary) / "test.mxl"
            raw = score([note() * 4]).replace(b"<score-partwise>", b'<score-partwise xmlns="http://www.musicxml.org/ns/musicxml">')
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="score/main.xml" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles></container>')
                archive.writestr("score/main.xml", raw)
                archive.writestr("wrong.xml", "not the score")
            self.assertEqual(read_xml(path), raw)
            self.assertEqual(analyze(path, question_id="zip")["metrics"]["attack_count"], 4)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="../escape.xml"/></rootfiles></container>')
                archive.writestr("../escape.xml", raw)
            with self.assertRaisesRegex(FeatureError, "invalid_mxl_path"):
                read_xml(path)


if __name__ == "__main__":
    unittest.main()
