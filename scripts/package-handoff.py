"""Produce source handoff; credentials, student submissions and runtime files are excluded."""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/"dist"
OUTPUT.mkdir(exist_ok=True)
EXCLUDED={".git",".venv",".venv314",".local",".tmp","__pycache__",".build",".swiftpm","build","DerivedData","xcuserdata","media","staticfiles","node_modules","dist"}
ROOT_FILES={"README.md","compose.yaml",".gitignore",".gitattributes"}
ROOT_DIRS={"backend","frontend","docs","scripts",".github"}

def allowed(path):
    relative=path.relative_to(ROOT)
    if relative.parts[0] not in ROOT_DIRS and str(relative) not in ROOT_FILES:
        return False
    if any(part in EXCLUDED or part.startswith(".venv") for part in relative.parts):
        return False
    if path.name.startswith(".env") and path.name!=".env.example":
        return False
    if path.name=="Local.xcconfig" or path.suffix.lower() in {".pyc",".sqlite3",".db",".p12",".pem",".key",".mobileprovision",".xcuserstate"}:
        return False
    if ".sqlite3" in path.name or path.name == ".coverage":
        return False
    return path.is_file() and not path.is_symlink()

files=sorted((p for p in ROOT.rglob("*") if allowed(p)),key=lambda p:p.as_posix())
manifest=[]
with zipfile.ZipFile(OUTPUT/"SORI-iPad-source.zip","w",compression=zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        name=path.relative_to(ROOT).as_posix()
        data=path.read_bytes()
        import re
        if re.search(rb"sk-or-v1-[a-fA-F0-9]{32,}", data):
            raise RuntimeError("Secret-like content detected in source handoff")
        manifest.append({"path":name,"size":len(data),"sha256":hashlib.sha256(data).hexdigest()})
        archive.writestr("SORI/"+name,data)
(OUTPUT/"manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding="utf-8")
print(f"Packaged {len(files)} files: {OUTPUT / 'SORI-iPad-source.zip'}")
print("Excluded credentials, private images, databases and local environments.")
