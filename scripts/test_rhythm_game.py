"""Run the full real-corpus rhythm roundtrip and telemetry tests without Django."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
suite = unittest.defaultTestLoader.loadTestsFromName("solfege.tests_rhythm")
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
