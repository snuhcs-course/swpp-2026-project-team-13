"""Fetch a pinned external instrument bank before a Mac/Xcode build. Stdlib only.
No model/API credits are used. The application itself never downloads sounds.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"
COMMIT = "684543d5e5efaef08d02be50dcda8d552478fa60"
BASE = "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/" + COMMIT + "/"


def fetch(relative, limit):
    request = urllib.request.Request(BASE + relative, headers={"User-Agent": "SORI-build/1.0"})
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Sound bank download exceeds its size limit")
    return data


def presets(data):
    if data[:4] != b"RIFF" or data[8:12] != b"sfbk" or struct.unpack_from("<I", data, 4)[0] + 8 != len(data):
        raise ValueError("Expected an intact SoundFont 2 bank")
    cursor = 12
    while cursor + 8 <= len(data):
        size = struct.unpack_from("<I", data, cursor + 4)[0]
        end = cursor + 8 + size
        if end > len(data):
            raise ValueError("Truncated SoundFont chunk")
        if data[cursor:cursor+4] == b"LIST" and data[cursor+8:cursor+12] == b"pdta":
            child = cursor + 12
            while child + 8 <= end:
                length = struct.unpack_from("<I", data, child + 4)[0]
                if child + 8 + length > end:
                    raise ValueError("Invalid preset table")
                if data[child:child+4] == b"phdr":
                    table = data[child+8:child+8+length]
                    if len(table) % 38:
                        raise ValueError("Invalid preset header length")
                    return {(struct.unpack_from("<H",table,i+20)[0], struct.unpack_from("<H",table,i+22)[0]) for i in range(0,len(table)-38,38)}
                child += 8 + length + length % 2
        cursor = end + size % 2
    raise ValueError("Missing preset table")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify installed bytes without network")
    args = parser.parse_args()
    bank = RESOURCES / "GeneralUser-GS.sf2"
    descriptor = RESOURCES / "instrument-bank.json"
    license_file = RESOURCES / "generaluser-license.txt"
    if bank.exists() and descriptor.exists() and license_file.exists():
        meta = json.loads(descriptor.read_text(encoding="utf-8"))
        valid = meta["source_commit"] == COMMIT and hashlib.sha256(bank.read_bytes()).hexdigest() == meta["sha256"] and hashlib.sha256(license_file.read_bytes()).hexdigest() == meta["license_sha256"]
        if valid:
            presets(bank.read_bytes())
            print("PASS GeneralUser GS v2.0.3 pinned bank and license")
            return
    if args.check:
        parser.error("External sound bank missing or changed. Run python scripts/fetch_soundfont.py before building.")
    data = fetch("GeneralUser-GS.sf2", 40 * 1024 * 1024)
    choices = json.loads((RESOURCES / "instruments.json").read_text(encoding="utf-8"))["voices"]
    available = presets(data)
    if not all((v["program"], 0) in available for v in choices):
        raise ValueError("Bank does not contain every selected General MIDI preset")
    license_data = fetch("documentation/LICENSE.txt", 64 * 1024)
    if b"GeneralUser GS" not in license_data or b"software projects" not in license_data:
        raise ValueError("Unexpected license text")
    RESOURCES.mkdir(parents=True, exist_ok=True)
    bank.with_suffix(".download").write_bytes(data)
    bank.with_suffix(".download").replace(bank)
    license_file.write_bytes(license_data)
    meta = {"name":"GeneralUser GS", "version":"2.0.3", "source_commit":COMMIT, "source":"https://github.com/mrbumpy409/GeneralUser-GS", "sha256":hashlib.sha256(data).hexdigest(), "size_bytes":len(data), "license_sha256":hashlib.sha256(license_data).hexdigest()}
    descriptor.write_text(json.dumps(meta,indent=2)+"\n",encoding="utf-8")
    print("Installed GeneralUser GS v2.0.3 and original license; " + str(len(data)) + " bytes")


if __name__ == "__main__":
    main()
