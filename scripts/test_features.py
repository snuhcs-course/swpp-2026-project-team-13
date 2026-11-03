"""Run Feature v1 contract tests without installing Django or using AI."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))


class BackendLayoutTests(unittest.TestCase):
    def test_mxl_test_works_with_only_backend_copied_to_app(self):
        scratch = ROOT / "backend/.tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="feature-layout-", dir=scratch) as directory:
            layout = Path(directory).resolve()
            self.assertTrue(layout.is_relative_to(scratch.resolve()))
            app = layout / "app"
            package = app / "solfege"
            package.mkdir(parents=True)
            (package / "__init__.py").write_text("", encoding="utf-8")
            shutil.copyfile(ROOT / "backend/solfege/tests_features.py", package / "tests_features.py")
            shutil.copytree(ROOT / "backend/solfege/features", package / "features", ignore=shutil.ignore_patterns("__pycache__"))
            result = subprocess.run(
                [sys.executable, "-m", "unittest", "solfege.tests_features.FeatureTests.test_mxl_rootfile_and_namespace_are_respected"],
                cwd=app, capture_output=True, text=True, encoding="utf-8", timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((app / ".tmp/feature-tests").is_dir())
            self.assertFalse((layout / "backend").exists())

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromName("solfege.tests_features")
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(BackendLayoutTests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
