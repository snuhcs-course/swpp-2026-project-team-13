"""Export one Feature v1 analysis or span without Django, a server or AI."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from solfege.features import FeatureError, analyze, select_span


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--question-id", required=True)
    parser.add_argument("--version", type=int, default=1)
    parser.add_argument("--first", type=int)
    parser.add_argument("--last", type=int)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if (options.first is None) != (options.last is None):
        parser.error("--first and --last must be supplied together")
    try:
        payload = analyze(options.input, question_id=options.question_id, question_version=options.version)
        if options.first is not None:
            payload = select_span(payload, options.first, options.last)
    except (FeatureError, OSError) as error:
        parser.exit(1, f"Analysis failed: {error}\n")
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"Wrote {options.output}")


if __name__ == "__main__":
    main()
