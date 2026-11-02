"""Generate an offline game pool from current intermediate/advanced question versions."""
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from sori.rhythm import build_catalog


def main():
    catalog = build_catalog(ROOT / "backend/content")
    data = (json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    paths = [ROOT / "backend/content/rhythm-puzzle-v1.json", ROOT / "frontend/IPadApp/IPadApp/Resources/rhythm-puzzle-v1.json"]
    if "--check" in sys.argv:
        for path in paths:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit(f"Regenerate Rhythm Puzzle: {path.relative_to(ROOT)}")
    else:
        for path in paths:
            path.write_bytes(data)
    reasons = {"external_tie": "구간 밖 음과 이어지는 타이", "needs_beat_grouping": "7/8 박 묶음 미정"}
    lines = ["# 리듬 퍼즐 출제 보류 구간", "", "자동 생성: `python scripts/build_rhythm_game.py`. 원본의 음가·타이를 임의로 바꾸지 않는다.", "",
             f"출제 가능: {len(catalog['rounds'])}구간 · 보류: {len(catalog['exceptions'])}구간.", "", "| 원곡 | 마디 | 사유 |", "|---|---|---|"]
    for e in catalog["exceptions"]:
        lines.append(f"| {e['title']} | {e['first_measure']}–{e['first_measure']+1} | {reasons.get(e['reason'], e['reason'])} |")
    report = ("\n".join(lines)+"\n").encode()
    report_path = ROOT / "docs/RHYTHM-PUZZLE-EXCEPTIONS.md"
    if "--check" in sys.argv:
        if not report_path.exists() or report_path.read_bytes() != report:
            raise SystemExit("Regenerate Rhythm Puzzle exception report")
    else:
        report_path.write_bytes(report)
    print(f"Rhythm Puzzle: {len(catalog['rounds'])} rounds, {catalog['source_count']} sources, {len(catalog['tiles'])} pieces, {len(data)} bytes")
    print("Deferred spans:", dict(Counter(e["reason"] for e in catalog["exceptions"])))


if __name__ == "__main__":
    main()
