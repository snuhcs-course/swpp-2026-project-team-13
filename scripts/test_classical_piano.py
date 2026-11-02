"""Offline tests of classical piano installation, source credits and cache integrity."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import fetch_classical_piano as piano

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT/"frontend/IPadApp/IPadApp/Resources"


def archive(bank, extra_bank=False, symlink=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output,mode="w:bz2") as tar:
        # Archive names are deliberately untrusted: installation must use fixed paths.
        member = tarfile.TarInfo("../../outside.sf2")
        if symlink:
            member.type = tarfile.SYMTYPE; member.linkname = "/outside"
            tar.addfile(member)
        else:
            member.size = len(bank); tar.addfile(member,io.BytesIO(bank))
        if extra_bank:
            other = tarfile.TarInfo("other.sf2"); other.size = len(bank)
            tar.addfile(other,io.BytesIO(bank))
        credits = b"Original author and SoundFont credits; CC BY 3.0.\n"
        readme = tarfile.TarInfo("package/README.txt"); readme.size = len(credits)
        tar.addfile(readme,io.BytesIO(credits))
    return output.getvalue()


class ClassicalPianoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A real existing, original SF2 is a fixture for the installer, not the new timbre.
        cls.bank = (RESOURCES/"sori-piano-v2.sf2").read_bytes()
        cls.archive = archive(cls.bank)

    @contextlib.contextmanager
    def destination(self):
        scratch = ROOT/".tmp"; scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="classical-piano-",dir=scratch) as directory:
            destination = Path(directory).resolve()
            self.assertTrue(destination.is_relative_to(scratch.resolve()))
            (destination/"melody-piano-profile.json").write_bytes((RESOURCES/"melody-piano-profile.json").read_bytes())
            yield destination

    def test_original_bank_bytes_and_author_credits_are_preserved(self):
        bank, credits = piano.unpack(self.archive)
        self.assertEqual(bank,self.bank)
        self.assertIn("Original author",credits[0][1])

    def test_multiple_banks_symlinks_and_oversized_banks_are_rejected(self):
        for data in [archive(self.bank,extra_bank=True),archive(self.bank,symlink=True)]:
            with self.assertRaises(ValueError): piano.unpack(data)
        with patch.object(piano,"BANK_LIMIT",1), self.assertRaises(ValueError):
            piano.unpack(self.archive)
        with patch.object(piano,"ARCHIVE_LIMIT",1), self.assertRaises(ValueError):
            piano.unpack(self.archive)

    def test_install_records_hashes_and_cached_build_never_downloads(self):
        with self.destination() as destination, contextlib.redirect_stdout(io.StringIO()):
            with patch.object(piano,"download",return_value=self.archive) as download:
                piano.install(destination)
                download.assert_called_once()
            bank = destination/"melody-classical-piano.sf2"
            self.assertEqual(bank.read_bytes(),self.bank)
            meta = json.loads((destination/"melody-piano-bank.json").read_text(encoding="utf-8"))
            self.assertEqual(meta["sha256"],hashlib.sha256(self.bank).hexdigest())
            text = (destination/"melody-piano-license.txt").read_text(encoding="utf-8")
            self.assertIn("Zenph Studios",text); self.assertIn("Original author",text)
            with patch.object(piano,"download",side_effect=AssertionError("Unexpected download")):
                piano.install(destination,check=True)

    def test_modified_bank_or_removed_credits_fail_cache_verification(self):
        with self.destination() as destination, contextlib.redirect_stdout(io.StringIO()):
            with patch.object(piano,"download",return_value=self.archive): piano.install(destination)
            (destination/"melody-classical-piano.sf2").write_bytes(b"changed")
            with self.assertRaises(ValueError): piano.install(destination,check=True)
            (destination/"melody-classical-piano.sf2").write_bytes(self.bank)
            (destination/"melody-piano-license.txt").write_text("changed",encoding="utf-8")
            with self.assertRaises(ValueError): piano.install(destination,check=True)

    def test_missing_bank_check_does_not_attempt_network(self):
        with self.destination() as destination, patch.object(piano,"download",side_effect=AssertionError("Unexpected download")):
            with self.assertRaises(ValueError): piano.install(destination,check=True)


if __name__ == "__main__":
    unittest.main()
