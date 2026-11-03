"""Validate self-review and AI evidence without Django or paid model calls."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName("solfege.tests_learning_records"))
    sys.exit(not result.wasSuccessful())
