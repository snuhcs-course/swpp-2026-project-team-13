"""Offline portraits must not make iPad builds depend on Wikimedia availability."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fetch_composer_portraits import verify_portraits


class PortraitTests(unittest.TestCase):
    def test_repository_portraits_verify_without_network(self):
        with patch("socket.create_connection",side_effect=AssertionError("No network in portrait verification")) as connect:
            bundled, remote = verify_portraits()
        connect.assert_not_called()
        self.assertGreaterEqual(bundled,8)
        self.assertEqual(bundled+len(remote),9)
        self.assertLessEqual(set(remote),{"satie"})

    def fixture(self, root, *, composer="satie", remote=True, git_blob=False):
        resources=root/"Resources";resources.mkdir()
        assets=root/"Assets.xcassets";assets.mkdir()
        data=b"\xff\xd8pinned-portrait\xff\xd9"
        item={"id":composer,"resource":"composer-"+composer}
        if remote:item["remote"]="https://example.test/original.jpg"
        if git_blob:
            item["git_blob_sha"]=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
        else:item.update(sha1=hashlib.sha1(data).hexdigest(),size_bytes=len(data))
        (resources/"composer-portraits.json").write_text(json.dumps([item]),encoding="utf-8")
        folder=assets/(item["resource"]+".imageset");folder.mkdir()
        (folder/"Contents.json").write_text(json.dumps({"images":[{"filename":"portrait.jpg"}]}),encoding="utf-8")
        return resources,assets,folder/"portrait.jpg",data

    def test_only_optional_satie_can_use_existing_remote_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            resources,assets,path,data=self.fixture(Path(directory))
            with patch("socket.create_connection") as connect:
                self.assertEqual(verify_portraits(resources,assets),(0,["satie"]))
            connect.assert_not_called()
            self.assertFalse(path.exists())
            with self.assertRaises(FileNotFoundError):verify_portraits(resources,assets,require_all=True)

    def test_missing_required_photo_still_fails_even_with_remote_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            resources,assets,path,data=self.fixture(Path(directory),composer="mahler")
            with self.assertRaises(FileNotFoundError):verify_portraits(resources,assets)

    def test_local_satie_must_match_pinned_bytes_and_asset_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            resources,assets,path,data=self.fixture(Path(directory))
            path.write_bytes(data)
            self.assertEqual(verify_portraits(resources,assets,require_all=True),(1,[]))
            path.write_bytes(data[:-1]+b"x")
            with self.assertRaisesRegex(ValueError,"integrity"):verify_portraits(resources,assets)
            self.assertEqual(path.read_bytes(),data[:-1]+b"x")
            path.write_bytes(data)
            (path.parent/"Contents.json").write_text('{"images":[]}',encoding="utf-8")
            with self.assertRaisesRegex(ValueError,"asset catalog"):verify_portraits(resources,assets)

    def test_checked_in_portraits_keep_git_blob_integrity_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            resources,assets,path,data=self.fixture(Path(directory),composer="mahler",remote=False,git_blob=True)
            path.write_bytes(data)
            self.assertEqual(verify_portraits(resources,assets),(1,[]))
            path.write_bytes(data+b"x")
            with self.assertRaisesRegex(ValueError,"integrity"):verify_portraits(resources,assets)


if __name__=="__main__":unittest.main()
