"""Print bounded app crash diagnostics after xcresulttool export (no extraction)."""
from pathlib import Path
import json
import sys
import zipfile


def report(name, raw):
    if "IPadApp" not in name and b'"procName" : "IPadApp"' not in raw and b'"procName":"IPadApp"' not in raw:
        return False
    print(f"\n--- Simulator app diagnostic: {name} ---")
    text = raw.decode("utf-8", errors="replace")
    try:
        diagnostic, end = json.JSONDecoder().raw_decode(text.lstrip())
        if "threads" not in diagnostic:
            diagnostic = json.loads(text.lstrip()[end:].lstrip())
        threads = diagnostic["threads"]
        fault = diagnostic.get("faultingThread")
        print(json.dumps({key:diagnostic.get(key) for key in
                          ("procName", "exception", "termination", "faultingThread")}, indent=2))
        # A single compact IPS threads line can exceed the whole log budget.
        # Print the actual crash and main thread before truncating other data.
        selected = [fault, 0] if isinstance(fault, int) and fault != 0 else [0]
        for index in selected:
            if 0 <= index < len(threads):
                print(f"Thread {index}:")
                print(json.dumps(threads[index], indent=2)[:10000])
    except (ValueError, KeyError, TypeError):
        print(text[:24000])
    return True


def main(root):
    count = 0
    for path in sorted(root.rglob("*")):
        if count >= 6:
            break
        if path.suffix.lower() in (".ips", ".crash", ".hang", ".spin"):
            count += report(path.name, path.read_bytes()[:2*1024*1024])
        elif path.suffix.lower() == ".zip":
            try:
                with zipfile.ZipFile(path) as archive:
                    for name in archive.namelist():
                        if count >= 6:
                            break
                        if Path(name).suffix.lower() in (".ips", ".crash", ".hang", ".spin"):
                            with archive.open(name) as file:
                                count += report(name, file.read(2*1024*1024))
            except (OSError, zipfile.BadZipFile):
                continue
    print(f"Printed {count} app crash diagnostics from {root}.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
