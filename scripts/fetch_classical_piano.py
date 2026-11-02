"""Install the versioned FreePats YDP Grand Piano before building the iPad app.

The app never downloads audio. Extract only bounded regular files into memory,
retain original credits, and verify the bank and credits on every cached build.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

from fetch_soundfont import presets

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT/"frontend/IPadApp/IPadApp/Resources"
ARCHIVE_LIMIT = 64*1024*1024
BANK_LIMIT = 180*1024*1024


def download(url):
    request = urllib.request.Request(url,headers={"User-Agent":"SORI-build/1.0"})
    with urllib.request.urlopen(request,timeout=60) as response:
        data = response.read(ARCHIVE_LIMIT+1)
    if len(data) > ARCHIVE_LIMIT:
        raise ValueError("Classical piano archive exceeds its size limit")
    return data


def unpack(data):
    if len(data) > ARCHIVE_LIMIT:
        raise ValueError("Classical piano archive exceeds its size limit")
    with tarfile.open(fileobj=io.BytesIO(data),mode="r:bz2") as archive:
        members = archive.getmembers()
        if len(members) > 128:
            raise ValueError("Unexpected piano archive contents")
        banks = [m for m in members if m.isfile() and m.name.lower().endswith(".sf2")]
        if len(banks) != 1 or not 0 < banks[0].size <= BANK_LIMIT:
            raise ValueError("Expected exactly one bounded SoundFont 2 bank")
        with archive.extractfile(banks[0]) as stream:
            bank = stream.read(BANK_LIMIT+1)
        if len(bank) != banks[0].size or (0,0) not in presets(bank):
            raise ValueError("YDP bank must contain acoustic piano program 0, bank 0")
        originals = []
        for member in members:
            if member.isfile() and Path(member.name).name.lower().startswith(("readme","license","copying")):
                if member.size > 64*1024:
                    raise ValueError("Oversized piano credit file")
                with archive.extractfile(member) as stream:
                    originals.append((Path(member.name).name,stream.read().decode("utf-8",errors="replace")))
        return bank, originals


def install(resources=RESOURCES, check=False):
    profile = json.loads((resources/"melody-piano-profile.json").read_text(encoding="utf-8"))
    bank_path = resources/profile["resource"]
    descriptor = resources/"melody-piano-bank.json"
    credit_path = resources/"melody-piano-license.txt"
    if bank_path.exists() and descriptor.exists() and credit_path.exists():
        meta = json.loads(descriptor.read_text(encoding="utf-8"))
        bank = bank_path.read_bytes()
        if (meta.get("id") == profile["id"] and meta.get("source_url") == profile["source_url"]
                and len(bank) == meta.get("size_bytes")
                and hashlib.sha256(bank).hexdigest() == meta.get("sha256")
                and hashlib.sha256(credit_path.read_bytes()).hexdigest() == meta.get("license_sha256")
                and (0,0) in presets(bank)):
            print("PASS YDP Grand Piano bank and original credits")
            return
    if check:
        raise ValueError("Classical piano missing or changed. Run python scripts/fetch_classical_piano.py before building.")
    bank, originals = unpack(download(profile["source_url"]))
    credits = ("YDP Grand Piano (FreePats, 2016-08-04)\n"
               "Yamaha Disklavier Pro Piano Multisamples by Zenph Studios, performed and recorded by Dr. Mikhail Krishtal and team for OLPC.\n"
               "SoundFont and sample modifications by Roberto for FreePats.\n"
               "Source: "+profile["source_page"]+"\n"
               "License: Creative Commons Attribution 3.0 Unported (CC BY 3.0)\n"
               "https://creativecommons.org/licenses/by/3.0/\n"
               "SORI uses the original SF2 bytes without sample edits; playback uses a medium MIDI velocity and reduced output gain. No endorsement is implied.\n")
    for name, text in originals:
        credits += "\n--- Original "+name+" ---\n"+text+"\n"
    credit_bytes = credits.encode("utf-8")
    # Fixed output names; archive entry paths are never extracted to disk.
    bank_path.with_suffix(".download").write_bytes(bank)
    bank_path.with_suffix(".download").replace(bank_path)
    credit_path.write_bytes(credit_bytes)
    metadata = dict(id=profile["id"],source_url=profile["source_url"],size_bytes=len(bank),
                    sha256=hashlib.sha256(bank).hexdigest(),license_sha256=hashlib.sha256(credit_bytes).hexdigest())
    descriptor.write_text(json.dumps(metadata,indent=2)+"\n",encoding="utf-8")
    print("Installed YDP Grand Piano and credits; "+str(len(bank))+" bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true")
    args = parser.parse_args()
    try:
        install(check=args.check)
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1,"Classical piano setup failed: "+str(error)+"\n")


if __name__ == "__main__":
    main()
