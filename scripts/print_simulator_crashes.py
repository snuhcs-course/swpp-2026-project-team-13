"""Print bounded app crash diagnostics after xcresulttool export (no extraction)."""
from pathlib import Path
import sys
import zipfile


def report(name, raw):
    if "IPadApp" not in name and b'"procName" : "IPadApp"' not in raw and b'"procName":"IPadApp"' not in raw:
        return False
    print(f"\n--- Simulator app diagnostic: {name} ---")
    print(raw.decode("utf-8", errors="replace")[:24000])
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
