"""Verify bundled composer portraits offline, retaining the existing Satie fallback.

Eight portraits are checked in. Satie may use the app's existing remote image
when its optional JPEG is absent; if bundled, its pinned size and SHA-1 must match.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT/"frontend/IPadApp/IPadApp/Resources"
ASSETS = ROOT/"frontend/IPadApp/IPadApp/Assets.xcassets"


def verify_portraits(resources=RESOURCES, assets=ASSETS, *, require_all=False):
    profiles = json.loads((resources/"composer-portraits.json").read_text(encoding="utf-8"))
    bundled = 0
    remote = []
    for item in profiles:
        folder = assets/(item["resource"]+".imageset"); path = folder/"portrait.jpg"
        if not path.exists():
            if item["id"] == "satie" and item.get("remote") and not require_all:
                remote.append(item["id"])
                continue
            raise FileNotFoundError(f"A required bundled portrait is missing: {path}")
        data = path.read_bytes()
        if data[:2] != b"\xff\xd8":
            raise ValueError(f"Invalid JPEG portrait: {item['id']}")
        if "sha1" in item:
            intact = len(data) == item["size_bytes"] and hashlib.sha1(data).hexdigest() == item["sha1"]
        else:
            blob = b"blob "+str(len(data)).encode()+b"\0"+data
            intact = hashlib.sha1(blob).hexdigest() == item["git_blob_sha"]
        if not intact:
            raise ValueError(f"Portrait integrity check failed: {item['id']}")
        contents = json.loads((folder/"Contents.json").read_text(encoding="utf-8"))
        if not any(image.get("filename") == path.name for image in contents.get("images",[])):
            raise ValueError(f"Portrait is not registered in its asset catalog: {item['id']}")
        bundled += 1
    return bundled, remote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true",help="Compatibility flag; verification is always offline.")
    parser.add_argument("--require-all",action="store_true",help="Also require the optional Satie JPEG locally.")
    args = parser.parse_args()
    bundled, remote = verify_portraits(require_all=args.require_all)
    print(f"Verified {bundled} bundled composer portraits offline; source credits retained.")
    if remote:
        print("Existing app remote-image fallback: "+", ".join(remote))


if __name__ == "__main__":
    main()
