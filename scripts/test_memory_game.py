"""Verify Memory run's actual music and novice pool, without an iPad or server."""
from collections import Counter
from fractions import Fraction as F
import hashlib
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

import build_memory_game as builder
from import_melody_library import inspect
from test_melody_library import musical_signature
from solfege.features import analyze_bytes, select_span
from solfege.features.musicxml import read_xml, parse_xml
from solfege.rhythm import current_sources

RES = builder.RES


class MemoryGameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((RES / "memory-run-v2.json").read_text(encoding="utf-8"))
        cls.sources = {q["id"]: q for q in cls.data["sources"]}

    def test_frozen_data_is_reproducible_and_original_pool_unchanged(self):
        catalog, generated, report = builder.build()
        self.assertEqual(catalog, self.data)
        self.assertEqual(json.loads(json.dumps(report)), json.loads((builder.ROOT / "docs/memory-import-report.json").read_text(encoding="utf-8")))
        original = json.loads((RES / "melody-catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(len(original), 923)
        self.assertTrue({q["id"] for q in original} <= self.sources.keys())
        for name, data in generated.items():
            self.assertEqual((RES / name).read_bytes(), data)

    def test_only_requested_additional_sources_are_used_with_latest_notes_unchanged(self):
        current = {r["metadata"]["id"]: r for r in current_sources(builder.ROOT / "backend/content", include_classical=True)}
        self.assertEqual(Counter(q["collection"] for q in self.sources.values()), {"library": 923, "intermediate": 11, "classical": 33})
        for q in self.sources.values():
            data = (RES / q["file"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), q["sha256"])
            inspect(data)  # Checks all eight bars, note durations, ties, clefs and 480 PPQ.
            if q["collection"] == "library":
                continue
            row = current[q["id"]]
            m = row["metadata"]
            self.assertTrue(m.get("collection") == "classical" or m.get("difficulty") == "intermediate")
            self.assertEqual(q["version"], m["version"])
            raw = read_xml(builder.ROOT / "backend/content" / row["main_path"])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), q["originalXmlSha256"])
            self.assertEqual(musical_signature(parse_xml(raw)), musical_signature(ET.fromstring(data)))
            if q["collection"] == "classical":
                self.assertTrue(q["sourceLabel"].endswith(" 中"))

    def test_every_excerpt_has_closed_ties_exact_timing_and_real_pitch_features(self):
        groups = {}
        for e in self.data["excerpts"]:
            groups.setdefault(e["sourceId"], []).append(e)
            self.assertIn(e["bars"], (2, 4))
            self.assertTrue(0 <= e["score"] <= 100)
            self.assertEqual(e["first"] % e["bars"], 1)
        self.assertEqual(len({e["id"] for e in self.data["excerpts"]}), len(self.data["excerpts"]))
        for q in self.sources.values():
            a = analyze_bytes((RES / q["file"]).read_bytes(), question_id=q["id"], question_version=q.get("version", 1))
            self.assertEqual(a["analysis_key"], q["analysisKey"])
            for e in groups[q["id"]]:
                span = select_span(a, e["first"], e["first"]+e["bars"]-1)
                self.assertFalse(span["external_ties"])
                actual = builder.burden(a, e["first"], e["bars"])
                for k, v in actual.items():
                    self.assertEqual(e[k], v, (e["id"], k))
                ids = set(span["event_ids"])
                attacks = [n for n in a["attacks"] if n["id"] in ids]
                self.assertEqual(len(attacks), e["attacks"])
                self.assertTrue(all((F(n["sounding_duration_qn"])*480).denominator == 1 for n in attacks))

    def test_beginner_and_first_two_intro_rounds_are_accessible(self):
        simple = [e for e in self.data["excerpts"] if e["beginnerEligible"]]
        self.assertGreater(len(simple), 100)
        intro = [e for e in simple if e["attacks"] <= 5 and e["pitchRange"] <= 5 and e["largestInterval"] <= 2]
        self.assertGreater(len({e["sourceId"] for e in intro}), 10)
        for e in simple:
            q = self.sources[e["sourceId"]]
            self.assertEqual((q["fifths"], q["mode"]), (0, "major"))
            self.assertTrue(3 <= e["attacks"] <= 8)
            self.assertEqual(e["bars"], 2)
            self.assertLessEqual(e["pitchRange"], 7)
            self.assertTrue(e["lowestMidi"] >= 60 and e["highestMidi"] <= 72)
            self.assertEqual(e["chromaticShare"], 0)
            self.assertGreaterEqual(e["shortestQuarter"], .5)

    def test_interval_difficulty_is_not_a_rhythm_only_score(self):
        q = next(q for q in self.sources.values() if q["collection"] == "library")
        raw = (RES / q["file"]).read_bytes()
        root = ET.fromstring(raw)
        # Same rhythm: a repeated C4 versus alternating C4/C5 creates more pitch burden.
        pitches = root.findall("part/measure/note/pitch")
        for p in pitches:
            p.find("step").text = "C"; p.find("octave").text = "4"
            if p.find("alter") is not None: p.find("alter").text = "0"
        for n in root.findall("part/measure/note"):
            for tie in list(n.findall("tie")): n.remove(tie)
        easy = analyze_bytes(ET.tostring(root), question_id="pitch-probe")
        for i, p in enumerate(pitches): p.find("octave").text = str(4+i % 2)
        hard = analyze_bytes(ET.tostring(root), question_id="pitch-probe")
        a, b = builder.burden(easy, 1, 2), builder.burden(hard, 1, 2)
        self.assertEqual(a["rhythm"], b["rhythm"])
        self.assertGreater(b["pitch"], a["pitch"])
        self.assertGreater(b["raw"], a["raw"])


if __name__ == "__main__":
    unittest.main()
