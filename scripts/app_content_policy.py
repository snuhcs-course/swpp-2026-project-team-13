"""Prune built device resources, keeping runtime assets and a tiny sample pack.

Source fixtures are never deleted. Simulator builds keep full fixtures unless
SORI_FULL_DEMO=NO. Device installations use online content by default.
"""
import argparse
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'frontend/IPadApp/IPadApp/Resources'
RUNTIME = {
    'sori-click-v1.wav', 'instruments.json', 'GeneralUser-GS.sf2',
    'instrument-bank.json', 'generaluser-license.txt',
    'melody-classical-piano.sf2', 'melody-piano-bank.json',
    'melody-piano-profile.json', 'melody-piano-license.txt',
    'melody-source-license.txt', 'composer-portraits.json',
    'memory-glyphs-v1.json', 'rhythm-engraving-v3.json',
    'me.json', 'attempt-ready.json', 'answer-upload.json',
    'grading-queued.json', 'grading-processing.json', 'grading-completed.json',
    'grading-failed.json', 'grading-needs-review.json',
}

def allowed_files(resources=RESOURCES):
    index = json.loads((resources/'small-demo-index.json').read_text(encoding='utf-8'))
    names = RUNTIME | set(index['required_files']) | {'small-demo-index.json'}
    if any(Path(name).name != name or name in ('.','..') for name in names):
        raise ValueError('Bundle policy only accepts resource basenames')
    return names

def apply_policy(app, full=False, resources=RESOURCES):
    app=app.resolve(strict=True); resources=resources.resolve(strict=True)
    if app.suffix != '.app' or app == resources or app in resources.parents or resources in app.parents:
        raise ValueError('Expected a separate, built .app directory')
    allowed=allowed_files(resources)
    source=[p for p in resources.iterdir() if p.is_file()]
    removed=0; kept=0
    for path in source:
        target=app/path.name
        if target.is_symlink():raise ValueError('Unexpected resource symlink: '+path.name)
        if full or path.name in allowed:
            # Incremental builds can switch from slim back to full.
            if not target.exists():shutil.copyfile(path,target)
            kept += target.stat().st_size
        elif target.exists():
            target.unlink(); removed += path.stat().st_size
    marker={'version':1,'mode':'full-demo' if full else 'online',
            'resource_bytes':kept,'removed_bytes':removed}
    (app/'bundled-content.json').write_text(json.dumps(marker,indent=2)+'\n',encoding='utf-8')
    return marker

def verify_online(app, resources=RESOURCES):
    marker=json.loads((app/'bundled-content.json').read_text(encoding='utf-8'))
    if marker['mode'] != 'online':raise ValueError('The install build must use online content')
    allowed=allowed_files(resources)
    for path in resources.iterdir():
        if path.is_file() and path.name not in allowed and (app/path.name).exists():
            raise ValueError('Full-bank resource leaked into installation: '+path.name)
    for name in allowed:
        source=resources/name
        if not source.is_file() or not (app/name).is_file() or (app/name).read_bytes()!=source.read_bytes():
            raise ValueError('Missing or changed runtime/sample file: '+name)
    return marker

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    args=parser.parse_args()
    flag=os.environ.get('SORI_FULL_DEMO','').upper()
    full=flag=='YES' or (flag!='NO' and os.environ.get('PLATFORM_NAME')!='iphoneos')
    value=apply_policy(args.app,full)
    print(f"Bundle content: {value['mode']}, {value['resource_bytes']/1048576:.1f} MiB; removed {value['removed_bytes']/1048576:.1f} MiB of test fixtures")
