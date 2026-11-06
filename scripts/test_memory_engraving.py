"""Validate the offline glyph artifact without installing MuseScore in CI."""
import hashlib
import json
import math
from pathlib import Path
import unittest
from build_memory_glyphs import STYLE, TYPES

ROOT = Path(__file__).resolve().parents[1]


class MemoryEngravingTests(unittest.TestCase):
    def test_every_required_symbol_has_finite_bounded_vector_geometry(self):
        bank = json.loads((ROOT/'frontend/IPadApp/IPadApp/Resources/memory-glyphs-v1.json').read_text())
        self.assertEqual(bank['style_sha256'],hashlib.sha256(STYLE.encode()).hexdigest())
        self.assertEqual(bank['staff_space'],8)
        required = {'clef-G','clef-F'} | {'accidental-'+str(i) for i in range(-2,3)}
        required |= {prefix+kind for prefix in ['note-','rest-'] for kind in TYPES}
        required |= {'flag-'+kind+'-'+direction for kind in ['eighth','16th','32nd','64th'] for direction in ['up','down']}
        self.assertEqual(set(bank['glyphs']),required)
        for key,glyph in bank['glyphs'].items():
            with self.subTest(glyph=key):
                self.assertTrue(glyph['commands'])
                for command in glyph['commands']:
                    self.assertEqual(len(command['values']),{'M':2,'L':2,'C':6,'Q':4,'Z':0}[command['op']])
                    self.assertTrue(all(math.isfinite(v) and abs(v)<100 for v in command['values']))


if __name__ == '__main__': unittest.main()
