"""Independent source-preservation and ingestion tests. No Swift, server or network needed."""
from fractions import Fraction
import csv
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile
import contextlib
import io
import xml.etree.ElementTree as ET

import import_melody_library as importer
from import_melody_library import inspect, compact

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT/"frontend/IPadApp/IPadApp/Resources"
COLLECTION = ROOT.parent/"ear_training_8bars_1047_XML_only/ear_training_8bars_1047"


def musical_signature(root):
    def tree(node):
        return (node.tag,tuple(sorted(node.attrib.items())),(node.text or "").strip(),tuple(tree(c) for c in node)) if node is not None else None
    notes = []
    for bar in root.findall("part/measure"):
        notes.append(tuple(tuple(tree(n.find(k)) for k in ("pitch","rest","duration","type","time-modification")) +
                           (len(n.findall("dot")),tuple(tree(t) for t in n.findall("tie")),tuple(tree(t) for t in n.findall("beam"))) for n in bar.findall("note")))
    return tree(root.find("part/measure/attributes/key")),tree(root.find("part/measure/attributes/time")),notes


class MelodyLibraryTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((RES/"melody-catalog.json").read_text(encoding="utf-8"))

    def test_catalog_resources_and_all_bars_are_exact(self):
        self.assertTrue(self.catalog)
        self.assertEqual(len({q["id"] for q in self.catalog}),len(self.catalog))
        meters, keys, clefs, tied = set(), set(), set(), 0
        for q in self.catalog:
            data = (RES/q["file"]).read_bytes()
            self.assertNotIn(b"<!DOCTYPE",data)
            root = ET.fromstring(data)
            self.assertEqual(len(root.findall("part")),1)
            self.assertEqual(len(root.findall("part/measure")),8)
            meters.add((q["beats"],q["beatType"]))
            keys.add(q["key"]); clefs.add(root.findtext("part/measure/attributes/clef/sign"))
            divisions = 0
            for bar in root.findall("part/measure"):
                divisions = int(bar.findtext("attributes/divisions",str(divisions)))
                self.assertEqual(sum(Fraction(int(n.findtext("duration")),divisions) for n in bar.findall("note")),Fraction(q["beats"]*4,q["beatType"]),q["id"])
                tied += len(bar.findall("note/tie"))
            pitches = [(int(n.findtext("pitch/octave"))+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[n.findtext("pitch/step")]+int(n.findtext("pitch/alter","0")) for n in root.findall("part/measure/note") if n.find("pitch") is not None]
            self.assertEqual((min(pitches),max(pitches)),(q["lowestMidi"],q["highestMidi"]))
        if len(self.catalog) > 900:
            self.assertIn((2,4),meters); self.assertIn((6,8),meters)
            self.assertGreater(len(keys),20); self.assertEqual(clefs,{"G","F"}); self.assertGreater(tied,100)

    @unittest.skipUnless(COLLECTION.exists(),"Original workspace corpus is not part of the application repository")
    def test_all_imported_music_matches_original_notation(self):
        with (COLLECTION/"problem_list.csv").open(encoding="utf-8-sig") as stream:
            rows = {r["id"]:r for r in csv.DictReader(stream)}
        for q in self.catalog:
            if q["id"] not in rows:
                continue  # User-added files have no original in the 1047-question collection.
            original = ET.fromstring((COLLECTION/rows[q["id"]]["xml_path"]).read_bytes())
            imported = ET.fromstring((RES/q["file"]).read_bytes())
            self.assertEqual(musical_signature(original),musical_signature(imported),q["id"])

    def test_ingestion_rejects_partial_bar_repeat_chord_and_entity(self):
        data = (RES/"melody--Batchellor-Charmbury-1884a_1-1-018.xml").read_bytes()
        inspect(data)
        for invalid in (
            data.replace(b"<duration>256</duration>",b"<duration>128</duration>"),
            data.replace(b"</measure>",b'<barline><repeat direction="backward" /></barline></measure>',1),
            data.replace(b"<pitch>",b"<chord /><pitch>",1),
            b"<!ENTITY x 'secret'>"+data,
        ):
            with self.assertRaises(ValueError): inspect(invalid)

    def test_compact_export_is_musically_idempotent(self):
        data = (RES/self.catalog[0]["file"]).read_bytes()
        before = ET.fromstring(data)
        after = ET.fromstring(compact(ET.fromstring(data)))
        self.assertEqual(musical_signature(before),musical_signature(after))

    def test_demo_key_metadata_matches_actual_zero_signature_major_and_minor_scores(self):
        demo_keys = set()
        for q in self.catalog:
            root = ET.fromstring((RES/q["file"]).read_bytes())
            fifths = int(root.findtext("part/measure/attributes/key/fifths","0"))
            mode = root.findtext("part/measure/attributes/key/mode","major")
            self.assertEqual((q["fifths"],q["mode"]),(fifths,mode),q["id"])
            eligible = q["fifths"] == 0 and q["mode"] in ("major","minor")
            self.assertEqual(eligible,q["key"] in ("C major","A minor"),q["id"])
            if eligible: demo_keys.add(q["key"])
        self.assertEqual(demo_keys,{"C major","A minor"})

    def test_append_adds_a_file_without_replacing_existing_questions(self):
        scratch = ROOT/".tmp"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="melody-import-",dir=scratch) as directory:
            temporary = Path(directory).resolve()
            self.assertTrue(temporary.is_relative_to(scratch.resolve()))
            source, resources = temporary/"source", temporary/"resources"
            source.mkdir(); resources.mkdir(); (temporary/"docs").mkdir()
            prior = self.catalog[0]
            (resources/prior["file"]).write_bytes((RES/prior["file"]).read_bytes())
            (resources/"melody-catalog.json").write_text(json.dumps([prior]),encoding="utf-8")
            (source/"additional.xml").write_bytes((RES/"melody--Batchellor-Charmbury-1884a_1-1-018.xml").read_bytes())
            with patch.object(importer,"ROOT",temporary), patch.object(importer,"RESOURCES",resources), patch("sys.argv",["import_melody_library.py","--source",str(source),"--append"]), contextlib.redirect_stdout(io.StringIO()):
                importer.main()
            result = json.loads((resources/"melody-catalog.json").read_text(encoding="utf-8"))
            self.assertEqual(len(result),2)
            self.assertEqual(next(q for q in result if q["id"] == prior["id"]),prior)
            added = next(q for q in result if q["id"] == "additional")
            self.assertTrue((resources/added["file"]).exists())


if __name__ == "__main__":
    unittest.main()
