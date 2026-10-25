"""Offline checks for lossless inputs, known-error diagnostics, and paid-call resumption."""
import argparse
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
import zipfile

spec = importlib.util.spec_from_file_location("handwriting_evaluation", Path(__file__).with_name("evaluate_handwriting.py"))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class InputTests(unittest.TestCase):
    def test_padding_retains_all_original_visible_pixels(self):
        for _, lines, _ in app.CASES:
            source = (app.WORKSPACE / "evaluation/runs/pdf-excerpts" / ("page-1-lines-" + lines + ".png")).read_bytes()
            w, h, original = app.decode_png(source)
            png, geometry = app.pad_png(source)
            out_w, out_h, padded = app.decode_png(png)
            self.assertEqual((out_w, out_h), (2660, 1692))
            x, y = geometry["offset_x"], geometry["offset_y"]
            self.assertEqual([row[x*3:(x+w)*3] for row in padded[y:y+h]], original)
            self.assertTrue(all(row == b"\xff"*(out_w*3) for row in padded[:y] + padded[y+h:]))
            self.assertTrue(all(row[:x*3] == b"\xff"*(x*3) and row[(x+w)*3:] == b"\xff"*((out_w-x-w)*3) for row in padded[y:y+h]))

    def test_known_dot_omission_is_distinct_from_correct_answer(self):
        reference = app.ROOT / "backend/content/questions/excerpt-3/v1/main.mxl"
        with zipfile.ZipFile(reference) as archive:
            xml = archive.read("score.xml").decode()
        root = ET.fromstring(xml)
        note = root.find("part").find("measure").findall("note")[3]
        self.assertEqual(note.findtext("pitch/step"), "A")
        self.assertEqual(note.findtext("pitch/octave"), "4")
        self.assertIsNotNone(note.find("dot"))
        self.assertFalse(app.xml_comparison(xml, xml, "excerpt-3")["confirmed_missing_dot"]["undotted_A4_recognized"])
        note.remove(note.find("dot"))
        divisions = int(root.find("part/measure/attributes/divisions").text)
        note.find("duration").text = str(divisions // 2)
        recognized = ET.tostring(root, encoding="unicode")
        self.assertTrue(app.xml_comparison(xml, recognized, "excerpt-3")["confirmed_missing_dot"]["undotted_A4_recognized"])


class FakeServer:
    def __init__(self, manifest, root):
        self.manifest, self.root = manifest, root
        self.questions = {}
        self.attempts, self.create_keys = {}, {}
        self.submissions = 0
        self.lose_first_response = False
        self.terminal_status = "completed"
        for item in manifest["cases"]:
            self.questions[item["question_id"]] = {
                "version": 1, "sheet_layout": {"id": "test-layout"},
                "score_assets": {"main": {"sha256": app.sha((root / item["reference_file"]).read_bytes())}},
            }

    def factory(self, base, token):
        self.base = base.rstrip("/")
        return self

    def request(self, path, method="GET", payload=None, key=None, content_type=None, accept=None):
        if path == "/api/v1/me/":
            return {"id": "test-user"}
        if path.startswith("/api/v1/questions/"):
            return copy.deepcopy(self.questions[path.strip("/").split("/")[-1]])
        if path == "/api/v1/attempts/":
            if key not in self.create_keys:
                identity = str(len(self.attempts) + 1)
                self.create_keys[key] = identity
                self.attempts[identity] = {"id": identity, "status": "ready", "question_id": payload["question_id"]}
            return copy.deepcopy(self.attempts[self.create_keys[key]])
        parts = path.strip("/").split("/")
        attempt = self.attempts[parts[3]]
        operation = parts[4] if len(parts) > 4 else ""
        item = next(c for c in self.manifest["cases"] if c["question_id"] == attempt["question_id"])
        png = (self.output / item["submitted_file"]).read_bytes()
        if not operation:
            return copy.deepcopy(attempt)
        if operation == "start":
            attempt["status"] = "in_progress"
            return copy.deepcopy(attempt)
        if operation == "answers":
            if method == "GET":
                return png
            return {"id": attempt["id"] + "-answer", "sha256": app.sha(png),
                    "image_url": "/api/v1/attempts/" + attempt["id"] + "/answers/image/"}
        if operation == "submit":
            if attempt["status"] != "submitted":
                self.submissions += 1
                attempt["status"] = "submitted"
            if self.lose_first_response:
                self.lose_first_response = False
                raise RuntimeError("Simulated lost response after server committed the paid submission")
        if operation in ("submit", "result"):
            return {"job_id": str(app.uuid.UUID(int=int(attempt["id"]))), "status": self.terminal_status,
                    "score": 0 if self.terminal_status == "completed" else None, "feedback": {"summary": "테스트", "recommendations": []},
                    "annotations": [], "failure": None}
        raise AssertionError(path)


class ResumeTests(unittest.TestCase):
    def setup_run(self, directory):
        root = Path(directory)
        output = root / "output"
        output.mkdir()
        token = root / "backend/.local/connection.txt"
        token.parent.mkdir(parents=True)
        token.write_text("개발 토큰: " + "a"*40, encoding="utf-8")
        cases = []
        for i in range(1, 4):
            slug = "excerpt-" + str(i)
            ref = root / (slug + ".mxl")
            ref.write_bytes(b"fake-reference-" + str(i).encode())
            png = b"prepared-png-" + str(i).encode()
            (output / (slug + ".png")).write_bytes(png)
            cases.append({"case": slug, "question_id": str(i), "question_version": 1,
                          "submitted_file": slug + ".png", "submitted_sha256": app.sha(png), "reference_file": ref.name})
        manifest = {"cases": cases, "limitations": ["offline test"]}
        server = FakeServer(manifest, root)
        server.output = output
        options = argparse.Namespace(base="http://127.0.0.1:8000", collect_only=False, wait_seconds=1)
        return root, output, manifest, server, options

    def test_resume_after_lost_submit_response_never_duplicates_paid_call(self):
        scratch = app.ROOT / ".tmp"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root, output, manifest, server, options = self.setup_run(directory)
            server.lose_first_response = True
            with mock.patch.object(app, "ROOT", root), mock.patch.object(app, "API", server.factory), mock.patch.object(app, "export_diagnostics", return_value=([], None)), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "Simulated"):
                    app.run(options, manifest, output)
                app.run(options, manifest, output)
                app.run(options, manifest, output)
            self.assertEqual(server.submissions, 3)
            self.assertEqual(len(server.attempts), 3)
            self.assertTrue(json.loads((output / "report.json").read_text(encoding="utf-8"))["all_terminal"])

    def test_failed_result_is_reported_without_automatic_paid_retry(self):
        scratch = app.ROOT / ".tmp"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root, output, manifest, server, options = self.setup_run(directory)
            server.terminal_status = "failed"
            with mock.patch.object(app, "ROOT", root), mock.patch.object(app, "API", server.factory), mock.patch.object(app, "export_diagnostics", return_value=([], None)), contextlib.redirect_stdout(io.StringIO()):
                app.run(options, manifest, output)
                app.run(options, manifest, output)
            self.assertEqual(server.submissions, 3)
            self.assertTrue(all(c["grading"]["status"] == "failed" for c in json.loads((output / "report.json").read_text(encoding="utf-8"))["cases"]))


if __name__ == "__main__":
    unittest.main()
