"""Bundle the CC0 Satie portrait at build time; six historical portraits are checked in.

The original JPEG's SHA-1 and byte count are pinned to its Wikimedia file record.
No image editing, third-party image libraries, or runtime download is required in CI builds.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time
from urllib.parse import quote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT/"frontend/IPadApp/IPadApp/Resources"
ASSETS = ROOT/"frontend/IPadApp/IPadApp/Assets.xcassets"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true")
    args = parser.parse_args()
    profiles = json.loads((RESOURCES/"composer-portraits.json").read_text(encoding="utf-8"))
    for item in profiles:
        folder = ASSETS/(item["resource"]+".imageset"); path = folder/"portrait.jpg"
        if not path.exists():
            assert item["id"] == "satie" and not args.check, "A bundled portrait is missing"
            filename = "Erik_Satie_portrait.jpg"
            prefix = hashlib.md5(filename.encode()).hexdigest()
            url = f"https://upload.wikimedia.org/wikipedia/commons/{prefix[0]}/{prefix[:2]}/{quote(filename)}"
            request = Request(url,headers={"User-Agent":"SORI-MusicStudy/1.0 (portrait asset build; source credits bundled)"})
            for attempt in range(3):
                try:
                    with urlopen(request,timeout=30) as response:
                        data = response.read(2_000_001)
                    assert data[:2] == b"\xff\xd8" and len(data) == item["size_bytes"]
                    assert hashlib.sha1(data).hexdigest() == item["sha1"]
                    break
                except Exception:
                    if attempt == 2: raise
                    time.sleep(2*(attempt+1))
            folder.mkdir(parents=True,exist_ok=True); path.write_bytes(data)
            (folder/"Contents.json").write_text(json.dumps({"images":[{"filename":"portrait.jpg","idiom":"universal"}],"info":{"author":"xcode","version":1}},indent=2)+"\n",encoding="utf-8")
        data = path.read_bytes()
        assert data[:2] == b"\xff\xd8"
        if "sha1" in item:
            assert len(data) == item["size_bytes"] and hashlib.sha1(data).hexdigest() == item["sha1"]
        else:
            blob = b"blob "+str(len(data)).encode()+b"\0"+data
            assert hashlib.sha1(blob).hexdigest() == item["git_blob_sha"]
    print(f"Verified {len(profiles)} bundled composer portraits and retained their source credits.")


if __name__ == "__main__":
    main()
