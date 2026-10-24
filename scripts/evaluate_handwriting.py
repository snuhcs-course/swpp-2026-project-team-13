"""Evaluate the three existing handwritten crops through the real SORI HTTP API.

Offline preparation is the default. --run permits at most one paid submission per
case in the saved state. Re-running resumes existing attempts; failed AI jobs are
reported and are never automatically retried. No third-party host packages needed.
"""
import argparse
import binascii
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
DEFAULT_OUTPUT = ROOT / "backend" / ".local" / "handwriting-evaluation"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
CASES = [
    ("excerpt-1", "1-2", "01-08"),
    ("excerpt-2", "3-4", "09-16"),
    ("excerpt-3", "5-6", "17-24"),
]


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path, value):
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(path)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def decode_png(data):
    """Read bounded, non-interlaced RGB/RGBA PNGs, retaining exact visible pixels."""
    if data[:8] != PNG_MAGIC:
        raise ValueError("Input is not PNG")
    offset, compressed, dimensions = 8, bytearray(), None
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        if len(payload) != length or offset + length + 12 > len(data):
            raise ValueError("Truncated PNG")
        crc = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        if binascii.crc32(kind + payload) & 0xffffffff != crc:
            raise ValueError("Invalid PNG CRC")
        if kind == b"IHDR":
            w, h, bits, colour, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if not (0 < w <= 2660 and 0 < h <= 1692) or bits != 8 or colour not in (2, 6) or (compression, filtering, interlace) != (0, 0, 0):
                raise ValueError("Expected bounded, non-interlaced 8-bit RGB/RGBA PNG")
            dimensions = (w, h, 3 if colour == 2 else 4)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
        offset += length + 12
    if dimensions is None:
        raise ValueError("Missing PNG dimensions")
    w, h, channels = dimensions
    stride = w * channels
    raw = zlib.decompress(compressed)
    if len(raw) != (stride + 1) * h:
        raise ValueError("Invalid PNG decompressed size")
    previous, rgb_rows = bytearray(stride), []
    for y in range(h):
        start = y * (stride + 1)
        kind, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind > 4:
            raise ValueError("Unsupported PNG filter")
        if kind:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                above = previous[i]
                upper_left = previous[i - channels] if i >= channels else 0
                if kind == 1:
                    predictor = left
                elif kind == 2:
                    predictor = above
                elif kind == 3:
                    predictor = (left + above) // 2
                else:
                    p = left + above - upper_left
                    da, db, dc = abs(p - left), abs(p - above), abs(p - upper_left)
                    predictor = left if da <= db and da <= dc else above if db <= dc else upper_left
                row[i] = (row[i] + predictor) & 255
        if channels == 4:
            if any(a != 255 for a in row[3::4]):
                raise ValueError("Source has transparency; inspect it before changing pixels")
            rgb = bytearray(w * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = row[0::4], row[1::4], row[2::4]
            rgb_rows.append(bytes(rgb))
        else:
            rgb_rows.append(bytes(row))
        previous = row
    return w, h, rgb_rows


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff)


def pad_png(data):
    w, h, rows = decode_png(data)
    width, height = 2660, 1692
    x, y = (width - w) // 2, (height - h) // 2
    white = b"\xff" * (width * 3)
    output = [white] * height
    for index, row in enumerate(rows):
        output[y + index] = b"\xff" * (x * 3) + row + b"\xff" * ((width - x - w) * 3)
    payload = zlib.compress(b"".join(b"\x00" + row for row in output), 9)
    png = PNG_MAGIC + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += png_chunk(b"IDAT", payload) + png_chunk(b"IEND", b"")
    return png, {"source_width": w, "source_height": h, "offset_x": x, "offset_y": y, "width": width, "height": height}


def prepare(output):
    output.mkdir(parents=True, exist_ok=True)
    catalog = json.loads((ROOT / "backend/content/catalog.json").read_text(encoding="utf-8"))
    # Catalog entries hold the registered immutable metadata and content paths.
    records = catalog["questions"] if isinstance(catalog, dict) else catalog
    prepared = []
    for index, (slug, lines, measures) in enumerate(CASES, 1):
        crop = WORKSPACE / "evaluation/runs/pdf-excerpts" / ("page-1-lines-" + lines + ".png")
        if not crop.exists():
            raise FileNotFoundError("Missing existing crop: " + str(crop))
        entry = records[index - 1]
        q = entry.get("metadata", entry)
        original = crop.read_bytes()
        png, geometry = pad_png(original)
        filename = slug + "-submitted.png"
        (output / filename).write_bytes(png)
        ref = ROOT / "backend/content/questions" / slug / "v1/main.mxl"
        with zipfile.ZipFile(ref) as archive:
            xml = archive.read("score.xml")
        prepared.append({
            "case": slug, "question_id": q["id"], "question_version": q["version"],
            "title": q["title"], "source_image": str(crop.relative_to(WORKSPACE)),
            "source_sha256": sha(original), "submitted_file": filename, "submitted_sha256": sha(png),
            "reference_sha256": sha(xml), "reference_file": str(ref.relative_to(ROOT)),
            "geometry": geometry, "source_measures": measures,
        })
    manifest = {
        "format_version": 1,
        "preprocessing": "Exact source RGB pixels, centered white padding only. No resizing or synthesis.",
        "limitations": [
            "Existing PDF handwriting, not a PencilKit export.",
            "The centered old staff geometry differs from the app template; bounding boxes are not evaluated.",
            "Only excerpt-3 measure 1 A4 has a user-confirmed missing dot; other handwriting is not independently labelled.",
            "AI scores are estimates. XML-to-answer differences are not automatically recognition mistakes.",
        ],
        "cases": prepared,
    }
    atomic_json(output / "inputs.json", manifest)
    return manifest


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Redirect refused; check the API origin")


class API:
    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.origin = urllib.parse.urlsplit(self.base)
        if self.origin.scheme not in ("http", "https") or not self.origin.hostname or self.origin.username or self.origin.password or self.origin.path or self.origin.query or self.origin.fragment:
            raise ValueError("--base must be an HTTP(S) origin without a path")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path, method="GET", payload=None, key=None, content_type=None, accept="application/json"):
        url = path if path.startswith(("http://", "https://")) else self.base + path
        target = urllib.parse.urlsplit(url)
        if (target.scheme, target.netloc) != (self.origin.scheme, self.origin.netloc):
            raise RuntimeError("Cross-origin request refused")
        headers = {"Accept": accept, "Authorization": "Bearer " + self.token}
        if key:
            headers["Idempotency-Key"] = key
        if isinstance(payload, dict):
            payload = json.dumps(payload).encode("utf-8")
            content_type = "application/json"
        if content_type:
            headers["Content-Type"] = content_type
        req = urllib.request.Request(url, data=payload, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as response:
                raw = response.read(11 * 1024 * 1024)
                return json.loads(raw) if accept == "application/json" else raw
        except urllib.error.HTTPError as error:
            raise RuntimeError("HTTP " + str(error.code) + " for " + target.path) from None
        except urllib.error.URLError as error:
            raise RuntimeError("Cannot connect to API: " + str(error.reason)) from None


def multipart(case, state, png):
    boundary = "sori-handwriting-" + state["upload_key"]
    fields = {"client_answer_id": state["client_answer_id"], "answer_format_version": "1", "sheet_layout_id": case["layout_id"]}
    chunks = []
    for name, value in fields.items():
        chunks.append(("--" + boundary + '\r\nContent-Disposition: form-data; name="' + name + '"\r\n\r\n' + value + "\r\n").encode())
    chunks.extend([
        ("--" + boundary + '\r\nContent-Disposition: form-data; name="image"; filename="handwriting.png"\r\nContent-Type: image/png\r\n\r\n').encode(),
        png, ("\r\n--" + boundary + "--\r\n").encode(),
    ])
    return b"".join(chunks), "multipart/form-data; boundary=" + boundary


def export_diagnostics(job_ids):
    if not job_ids:
        return [], None
    for value in job_ids:
        uuid.UUID(value)
    code = """import json,sys
from sori.models import GradingJob
ids=json.loads(sys.stdin.read())
fields=['id','attempt_id','answer_id','status','model','reasoning_effort','prompt_version','prompt_text','timeout_seconds','max_output_tokens','created_at','started_at','updated_at','usage','provider_request_id','recognized_musicxml','failure']
rows=list(GradingJob.objects.filter(id__in=ids).values(*fields))
print('SORI_EVALUATION_DIAGNOSTICS='+json.dumps(rows,ensure_ascii=True,default=str))
"""
    try:
        result = subprocess.run(
            ["docker", "compose", "--env-file", "backend/.env", "exec", "-T", "api",
             "python", "manage.py", "shell", "-c", code],
            input=json.dumps(job_ids), capture_output=True, text=True, encoding="utf-8", timeout=40, cwd=ROOT,
        )
        marker = "SORI_EVALUATION_DIAGNOSTICS="
        lines = [line[len(marker):] for line in result.stdout.splitlines() if line.startswith(marker)]
        if result.returncode or not lines:
            return [], "Diagnostics unavailable. Run this script in normal PowerShell with Docker Desktop running."
        return json.loads(lines[-1]), None
    except (OSError, subprocess.SubprocessError, ValueError):
        return [], "Diagnostics unavailable. API results are retained; re-run with --collect-only."


def events_from_xml(text):
    if len(text) > 500_000 or re.search(r"<!\s*ENTITY", text, re.I):
        raise ValueError("Unsupported or oversized recognition XML")
    root = ET.fromstring(text)
    for e in root.iter():
        e.tag = e.tag.rsplit("}", 1)[-1]
    parts = root.findall("part")
    if root.tag != "score-partwise" or len(parts) != 1:
        raise ValueError("Expected one-part score-partwise MusicXML")
    result, divisions = [], None
    for measure in parts[0].findall("measure"):
        cursor, notes = Fraction(0), []
        for element in measure:
            if element.tag == "attributes" and element.find("divisions") is not None:
                divisions = Fraction(element.findtext("divisions"))
                if divisions <= 0:
                    raise ValueError("Invalid divisions")
            elif element.tag in ("backup", "forward"):
                raise ValueError("Multiple-voice/offset XML requires manual review")
            elif element.tag == "note":
                if divisions is None or element.find("chord") is not None or element.find("grace") is not None:
                    raise ValueError("Unsupported note")
                duration = Fraction(element.findtext("duration")) / divisions
                if duration <= 0:
                    raise ValueError("Invalid duration")
                p = element.find("pitch")
                rest = element.find("rest") is not None
                if rest:
                    pitch = None
                elif p is not None:
                    step, octave = p.findtext("step"), int(p.findtext("octave"))
                    alteration = Fraction(p.findtext("alter", "0"))
                    if step not in ("C","D","E","F","G","A","B") or alteration.denominator != 1:
                        raise ValueError("Unsupported pitch")
                    pitch = (octave + 1) * 12 + {"C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11}[step] + int(alteration)
                else:
                    raise ValueError("Missing pitch/rest")
                notes.append({"midi": pitch, "onset_q": str(cursor), "duration_q": str(duration),
                              "dots": len(element.findall("dot")),
                              "ties": sorted(t.get("type") for t in element.findall("tie"))})
                cursor += duration
        result.append(notes)
    if len(result) != 8:
        raise ValueError("Expected eight recognized measures; manual review required")
    return result


def xml_comparison(reference, recognized, slug):
    actual = events_from_xml(recognized)
    expected = events_from_xml(reference)
    differences = []
    for measure, (a, b) in enumerate(zip(expected, actual), 1):
        # Do not force matching across inserted/deleted notes; such measures need human inspection.
        if len(a) != len(b):
            differences.append({"measure": measure, "kind": "event_count", "reference_count": len(a), "recognized_count": len(b)})
        else:
            for note, (x, y) in enumerate(zip(a, b), 1):
                fields = [field for field in x if x[field] != y[field]]
                if fields:
                    differences.append({"measure": measure, "note": note, "fields": fields, "reference": x, "recognized": y})
    result = {"reference_event_count": sum(map(len, expected)), "recognized_event_count": sum(map(len, actual)),
              "differences_from_answer": differences,
              "interpretation": "Differences from the correct answer, not independent recognition errors or a student grade."}
    if slug == "excerpt-3":
        target = actual[0][3] if len(actual[0]) > 3 else None
        result["confirmed_missing_dot"] = {
            "measure": 1, "note": 4, "pitch": "A4", "midi": 69,
            "observed_event": target,
            "undotted_A4_recognized": bool(target and target["midi"] == 69 and target["duration_q"] == "1/2" and target["dots"] == 0),
            "caution": "Automatic note-index check; verify the recognized sequence and feedback manually.",
        }
    return result


def collect(output, manifest, state, report):
    ids = [c["grading"]["job_id"] for c in report["cases"] if c.get("grading")]
    diagnostics, error = export_diagnostics(ids)
    report["diagnostics_error"] = error
    by_id = {str(row["id"]): row for row in diagnostics}
    costs = []
    for case in report["cases"]:
        grading = case.get("grading")
        if not grading:
            continue
        row = by_id.get(grading["job_id"])
        if not row:
            continue
        case["diagnostics"] = {k: v for k, v in row.items() if k != "recognized_musicxml"}
        usage = row.get("usage") or {}
        cost = usage.get("cost")
        if type(cost) in (int, float) and math.isfinite(cost) and cost >= 0:
            case["cost_usd"] = cost
            costs.append(cost)
        else:
            case["cost_usd"] = None
        if row.get("started_at"):
            start = datetime.fromisoformat(row["started_at"])
            end = datetime.fromisoformat(row["updated_at"])
            case["worker_elapsed_seconds"] = round((end - start).total_seconds(), 3)
        xml = row.get("recognized_musicxml") or ""
        if xml:
            (output / (case["case"] + "-recognized.musicxml")).write_text(xml, encoding="utf-8")
            prepared = next(c for c in manifest["cases"] if c["case"] == case["case"])
            with zipfile.ZipFile(ROOT / prepared["reference_file"]) as archive:
                reference = archive.read("score.xml").decode("utf-8")
            try:
                case["recognition_comparison"] = xml_comparison(reference, xml, case["case"])
            except (ET.ParseError, ValueError, TypeError, ZeroDivisionError, IndexError) as exc:
                case["recognition_comparison"] = {"parse_error": type(exc).__name__, "message": str(exc)}
    report["reported_cost_usd"] = round(sum(costs), 8) if costs else None
    report["cost_cases_available"] = len(costs)
    report["completed_at"] = utc_now()
    atomic_json(output / "report.json", report)
    lines = [
        "# 기존 필기 3문제 / 현재 SORI 서버 평가",
        "",
        "기존 PDF 필기에 흰 여백만 추가해 실제 API로 제출합니다. 실제 iPad 내보내기·오류 표시 좌표는 검증하지 않습니다.",
        "정답 XML과의 차이는 인식 오류와 학생의 오답을 자동으로 구분하지 못합니다.",
        "",
        "| 문제 | 상태 | AI 점수 | 제출→결과(초) | 워커 처리(초) | 실제 보고 비용(USD) |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for case in report["cases"]:
        g = case.get("grading") or {}
        lines.append("| " + " | ".join(str(v) for v in [
            case["case"], g.get("status", "미완료"), g.get("score"),
            case.get("submit_to_result_seconds"), case.get("worker_elapsed_seconds"), case.get("cost_usd"),
        ]) + " |")
    lines.extend(["", "비용 합계(확인된 요청만): " + str(report["reported_cost_usd"]) + " USD; 확인 " + str(len(costs)) + "/3건.",
                  "비용이 null이면 추정 금액으로 채우지 않습니다.", ""])
    if error:
        lines.extend([error, ""])
    for case in report["cases"]:
        g = case.get("grading") or {}
        lines.extend(["## " + case["case"], "", (g.get("feedback") or {}).get("summary", "결과 없음"), ""])
        for annotation in g.get("annotations", []):
            lines.append("- " + str(annotation.get("measure")) + "마디 / " + annotation["type"] + ": " + annotation["message"])
        for text in (g.get("feedback") or {}).get("recommendations", []):
            lines.append("- 연습 제안: " + text)
        comparison = case.get("recognition_comparison") or {}
        if "confirmed_missing_dot" in comparison:
            lines.extend(["", "알려진 A4 부점 누락 인식: " + str(comparison["confirmed_missing_dot"]["undotted_A4_recognized"]) + " (전체 순서·피드백 수동 확인 필요)"])
        if comparison.get("parse_error"):
            lines.extend(["", "인식 XML 파싱: " + comparison["message"]])
        if g.get("failure"):
            lines.extend(["", "채점 실패: " + json.dumps(g["failure"], ensure_ascii=False)])
        lines.append("")
    (output / "REPORT.md").write_text("\n".join(lines), encoding="utf-8")


def run(options, manifest, output):
    token_file = ROOT / "backend/.local/connection.txt"
    text = token_file.read_text(encoding="utf-8")
    match = re.search(r"개발 토큰:\s*([a-f0-9]{40})", text, re.I)
    if not match:
        raise RuntimeError("Development token not found in backend/.local/connection.txt")
    api = API(options.base, match.group(1))
    me = api.request("/api/v1/me/")
    state_path = output / "state.json"
    identity = {"base": api.base, "user_id": me["id"],
                "input_fingerprint": sha(json.dumps(manifest, sort_keys=True).encode("utf-8"))}
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if any(state.get(k) != v for k, v in identity.items()):
            raise RuntimeError("Saved run differs from API/user/inputs. Do not overwrite it; choose a new --output explicitly.")
    else:
        state = {**identity, "created_at": utc_now(), "cases": {}}
    report_path = output / "report.json"
    report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {
        "started_at": state["created_at"], "base": api.base, "limitations": manifest["limitations"], "cases": [],
    }
    save_state = lambda: atomic_json(state_path, state)
    save_report = lambda: atomic_json(report_path, report)
    save_state()
    try:
        for prepared in manifest["cases"]:
            slug = prepared["case"]
            previous = next((c for c in report["cases"] if c["case"] == slug), None)
            if previous is None:
                previous = {"case": slug}
                report["cases"].append(previous)
            cs = state["cases"].setdefault(slug, {
                "create_key": str(uuid.uuid4()), "upload_key": str(uuid.uuid4()),
                "submit_key": str(uuid.uuid4()), "client_answer_id": str(uuid.uuid4()),
            })
            save_state()
            question = api.request("/api/v1/questions/" + prepared["question_id"] + "/")
            if question["version"] != prepared["question_version"]:
                raise RuntimeError("Question version changed")
            if question["score_assets"]["main"]["sha256"] != sha((ROOT / prepared["reference_file"]).read_bytes()):
                raise RuntimeError("Server answer differs from local answer")
            cs["layout_id"] = question["sheet_layout"]["id"]
            save_state()
            if options.collect_only:
                if not cs.get("attempt_id"):
                    continue
            else:
                attempt = api.request("/api/v1/attempts/", "POST",
                    {"question_id": prepared["question_id"], "question_version": prepared["question_version"]}, cs["create_key"])
                cs["attempt_id"] = attempt["id"]
                save_state()
            path = "/api/v1/attempts/" + cs["attempt_id"]
            attempt = api.request(path + "/")
            if attempt["status"] != "submitted":
                if options.collect_only:
                    continue
                if attempt["status"] == "ready":
                    api.request(path + "/start/", "POST")
                png = (output / prepared["submitted_file"]).read_bytes()
                body, content_type = multipart(cs, cs, png)
                answer = api.request(path + "/answers/", "POST", body, cs["upload_key"], content_type)
                if answer["sha256"] != prepared["submitted_sha256"]:
                    raise RuntimeError("Upload hash mismatch")
                returned = api.request(answer["image_url"], accept="image/png")
                if returned != png:
                    raise RuntimeError("Downloaded answer differs from submitted PNG")
                cs["answer_id"] = answer["id"]
                if not cs.get("submitted_at"):
                    cs["submitted_at"] = utc_now()
                save_state()  # Persist the idempotency key and timing before any paid submission.
                grading = api.request(path + "/submit/", "POST", {"answer_id": answer["id"]}, cs["submit_key"])
            else:
                grading = api.request(path + "/result/")
            cs["job_id"] = grading["job_id"]
            previous["attempt_id"], previous["answer_id"] = cs["attempt_id"], cs.get("answer_id")
            previous["grading"] = grading
            save_state()
            save_report()
            deadline, last_status = time.monotonic() + options.wait_seconds, None
            while grading["status"] in ("queued", "processing"):
                if grading["status"] != last_status:
                    print(slug + ": " + grading["status"], flush=True)
                    last_status = grading["status"]
                if time.monotonic() >= deadline:
                    raise RuntimeError("Polling deadline reached. Re-run the same command to resume without a new paid call.")
                time.sleep(2)
                grading = api.request(path + "/result/")
                previous["grading"] = grading
                save_report()
            if not cs.get("terminal_observed_at"):
                cs["terminal_observed_at"] = utc_now()
                if cs.get("submitted_at"):
                    elapsed = datetime.fromisoformat(cs["terminal_observed_at"]) - datetime.fromisoformat(cs["submitted_at"])
                    cs["submit_to_result_seconds"] = round(elapsed.total_seconds(), 3)
            previous["submit_to_result_seconds"] = cs.get("submit_to_result_seconds")
            save_state()
            save_report()
            print(slug + ": " + grading["status"] + " / score=" + str(grading["score"]), flush=True)
        report["all_terminal"] = len(report["cases"]) == 3 and all(
            c.get("grading", {}).get("status") in ("completed", "needs_review", "failed") for c in report["cases"])
    finally:
        collect(output, manifest, state, report)
    print("Report: " + str(output / "REPORT.md"), flush=True)
    print("JSON: " + str(output / "report.json"), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--run", action="store_true", help="Submit the three prepared cases once; real AI charges apply")
    mode.add_argument("--collect-only", action="store_true", help="Read already-submitted results/diagnostics only")
    parser.add_argument("--base", default="http://127.0.0.1:8000")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--wait-seconds", type=int, default=360)
    options = parser.parse_args()
    output = options.output.resolve()
    manifest = prepare(output)
    print("Prepared 3 exact-pixel padded handwritten PNGs: " + str(output), flush=True)
    if options.run or options.collect_only:
        run(options, manifest, output)
    else:
        print("Offline only. Run with --run for actual HTTP submission and AI assessment.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print request headers, environment contents, or API credentials.
        print(type(error).__name__ + ": " + str(error), file=sys.stderr, flush=True)
        raise SystemExit(1)
