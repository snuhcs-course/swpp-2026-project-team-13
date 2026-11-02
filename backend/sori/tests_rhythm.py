import copy
import json
import unittest
import uuid
from fractions import Fraction as F
from pathlib import Path
from .features import analyze_bytes
from .rhythm import (VERSION, build_catalog, digest_bytes, grade, pieces_for_span,
                     rhythm_burden, sounding, source_symbols, tile)
from .rhythm_records import validate_record

ROOT = Path(__file__).resolve().parents[1]


def record_for(catalog, sha, r=None):
    r = r or catalog["rounds"][0]
    return dict(client_play_id=str(uuid.uuid4()), catalog_sha256=sha, round_id=r["id"], game_version=VERSION,
                choice_order=r["choices"], started_at="2026-11-03T00:00:00Z", finished_at="2026-11-03T00:01:00Z",
                outcome="correct", active_ms=60000, interruptions=0, prior_exposures=0, prior_pattern_exposures=0,
                listens=[dict(id=str(uuid.uuid4()), reason="initial", started_ms=0, ended_ms=30000, completed=True)],
                submissions=[dict(id=str(uuid.uuid4()), active_ms=40000, placements=copy.deepcopy(r["solution"]), ties=list(r["solution_ties"]))])


class RhythmTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        data = (ROOT / "content/rhythm-puzzle-v1.json").read_bytes()
        cls.catalog, cls.sha = json.loads(data), digest_bytes(data)
        cls.tiles = {t["id"]: t for t in cls.catalog["tiles"]}

    def test_every_round_can_be_solved_from_its_twelve_choices_and_matches_actual_audio(self):
        self.assertGreaterEqual(len(self.catalog["rounds"]), 250)
        for r in self.catalog["rounds"]:
            with self.subTest(round=r["id"]):
                self.assertIn(r["level"], ("intermediate", "advanced"))
                self.assertEqual(len(set(r["choices"])), 12)
                self.assertTrue(all(p["tile_id"] in r["choices"] for p in r["solution"]))
                answer = dict(placements=r["solution"], ties=r["solution_ties"])
                self.assertTrue(grade(r, answer, self.tiles)["correct"])
                self.assertEqual(r["rhythm"], [{k: n[k] for k in ("onset", "duration")} for n in r["audio"]])
                self.assertEqual(validate_record(record_for(self.catalog, self.sha, r), self.catalog, self.sha)[1]["first_correct"], True)

    def test_full_catalog_is_reproducible_and_mirrors_the_offline_app(self):
        regenerated = build_catalog(ROOT / "content")
        self.assertEqual(regenerated, self.catalog)
        app = ROOT.parent / "frontend/IPadApp/IPadApp/Resources/rhythm-puzzle-v1.json"
        if app.exists():  # The Docker runtime intentionally contains backend/ only.
            self.assertEqual(app.read_bytes(), (ROOT / "content/rhythm-puzzle-v1.json").read_bytes())

    def test_external_ties_and_unresolved_meter_are_explicitly_deferred(self):
        reasons = [e["reason"] for e in self.catalog["exceptions"]]
        self.assertEqual(reasons.count("external_tie"), 31)
        self.assertEqual(reasons.count("needs_beat_grouping"), 2)
        self.assertTrue(all(e["first_measure"] in (1, 3, 5, 7) for e in self.catalog["exceptions"]))

    def test_half_note_and_two_tied_quarters_have_identical_sound(self):
        def note(duration, typ):
            return dict(duration=duration, rest=False, type=typ, dots=0, actual=1, normal=1, group=0, group_end=False, tie_next=False)
        half, quarter = tile([note("2", "half")]), tile([note("1", "quarter")])
        tiles = {t["id"]: t for t in (half, quarter)}
        expected = sounding([dict(tile_id=half["id"], start="0")], [], tiles, F(2))
        actual = sounding([dict(tile_id=quarter["id"], start="0"), dict(tile_id=quarter["id"], start="1")], ["1"], tiles, F(2))
        self.assertEqual(actual, expected)
        self.assertNotEqual(sounding([dict(tile_id=quarter["id"], start="0"), dict(tile_id=quarter["id"], start="1")], [], tiles, F(2)), expected)

    def test_long_note_leaves_exact_fraction_and_tuplet_group_is_atomic(self):
        notes = []
        for i in range(3):
            notation = '<notations><tuplet type="start" number="1"/></notations>' if i == 0 else '<notations><tuplet type="stop" number="1"/></notations>' if i == 2 else ''
            notes.append('<note><pitch><step>C</step><octave>4</octave></pitch><duration>8</duration><type>quarter</type><time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>'+notation+'</note>')
        half = '<note><pitch><step>C</step><octave>4</octave></pitch><duration>24</duration><type>half</type></note>'
        raw = ('<score-partwise><part id="P1"><measure number="1"><attributes><divisions>12</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>'+''.join(notes)+half+'</measure><measure number="2">'+half+half+'</measure></part></score-partwise>').encode()
        a = analyze_bytes(raw, question_id="tuplets")
        _, placements, tiles, _ = pieces_for_span(a, source_symbols(a, raw), 1, 2)
        first = tiles[placements[0]["tile_id"]]
        self.assertEqual(first["duration"], "2")
        self.assertEqual([n["duration"] for n in first["symbols"]], ["2/3"] * 3)
        self.assertEqual(len(first["symbols"]), 3)
        self.assertTrue(any(t["duration"] == "3/2" for t in self.tiles.values()))
        self.assertTrue(any(t["duration"] == "1/2" for t in self.tiles.values()))

    def test_invalid_geometry_rest_ties_and_unknown_choices_are_not_graded(self):
        r = self.catalog["rounds"][0]
        answer = dict(placements=copy.deepcopy(r["solution"]), ties=list(r["solution_ties"]))
        answer["placements"].append(answer["placements"][0])
        with self.assertRaisesRegex(ValueError, "overlapping"):
            grade(r, answer, self.tiles)
        answer["placements"] = copy.deepcopy(r["solution"])
        answer["ties"] = ["0"]
        with self.assertRaises(ValueError):
            grade(r, answer, self.tiles)
        answer["ties"] = []
        answer["placements"][0]["tile_id"] = "unknown"
        with self.assertRaises(ValueError):
            grade(r, answer, self.tiles)

    def test_syncopation_outweighs_a_dense_but_regular_sixteenth_grid(self):
        regular = [dict(onset=str(F(i, 4)), duration="1/4") for i in range(16)]
        sync = [dict(onset="1/2", duration="1"), dict(onset="3/2", duration="1"), dict(onset="5/2", duration="1"), dict(onset="7/2", duration="1/2")]
        self.assertGreater(rhythm_burden(sync, "1", "4", "4")["raw"], rhythm_burden(regular, "1", "4", "4")["raw"])

    def test_records_pin_catalog_and_preserve_complete_and_interrupted_replays(self):
        p = record_for(self.catalog, self.sha)
        p["listens"] += [dict(id=str(uuid.uuid4()), reason="replay", started_ms=31000, ended_ms=32000, completed=False),
                         dict(id=str(uuid.uuid4()), reason="replay", started_ms=32000, ended_ms=39000, completed=True)]
        _, result = validate_record(p, self.catalog, self.sha)
        self.assertEqual(result["replay_started"], 2)
        self.assertEqual(result["replay_completed"], 1)
        self.assertEqual(result["results"][0]["hint_level_before"], 0)
        self.assertIn("difficulty", result["task"])
        p["catalog_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "catalog_version_mismatch"):
            validate_record(p, self.catalog, self.sha)

    def test_cannot_submit_before_listening_or_after_a_correct_result(self):
        p = record_for(self.catalog, self.sha)
        p["listens"][0]["completed"] = False
        with self.assertRaisesRegex(ValueError, "submit_before_complete_listen"):
            validate_record(p, self.catalog, self.sha)
        p["listens"][0]["completed"] = True
        p["submissions"].append(copy.deepcopy(p["submissions"][0]))
        with self.assertRaises(ValueError):
            validate_record(p, self.catalog, self.sha)

    def test_three_wrong_answers_remain_one_unaided_observation_with_two_assisted_retries(self):
        r = next(r for r in self.catalog["rounds"] if r["solution_ties"])
        p = record_for(self.catalog, self.sha, r)
        p["submissions"][0]["ties"] = []
        p["submissions"] = [dict(id=str(uuid.uuid4()), active_ms=40000+i*1000,
            placements=copy.deepcopy(r["solution"]), ties=[]) for i in range(3)]
        p["outcome"] = "revealed"
        _, result = validate_record(p, self.catalog, self.sha)
        self.assertEqual(result["first_correct"], False)
        self.assertEqual([r["hint_level_before"] for r in result["results"]], [0, 1, 2])
        self.assertTrue(result["calibration_eligible"])

    def test_malformed_records_do_not_accept_boolean_times_or_client_claimed_outcomes(self):
        for key, value in (("active_ms", True), ("client_play_id", 42), ("outcome", "perfect"), ("choice_order", [])):
            p = record_for(self.catalog, self.sha)
            p[key] = value
            with self.subTest(key=key), self.assertRaises((ValueError, TypeError)):
                validate_record(p, self.catalog, self.sha)


if __name__ == "__main__":
    unittest.main()
