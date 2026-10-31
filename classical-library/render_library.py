"""Rebuild the standalone HTML and 8-bar XML files from the checked-in selection data."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def main():
    data=json.loads((ROOT/'library-data.json').read_text(encoding='utf-8'))
    template=(ROOT/'library.template.html').read_text(encoding='utf-8')
    literal=json.dumps(data,ensure_ascii=False,separators=(',',':')).replace('</','<\\/')
    (ROOT/'CLASSICAL.html').write_text(template.replace('/*__DATA__*/',literal),encoding='utf-8')
    target=ROOT/'xml';target.mkdir(exist_ok=True)
    for item in data['items']:
        if item.get('ready'):(target/item['file']).write_text(item['xml'],encoding='utf-8')
    app=ROOT.parent/'frontend/IPadApp/IPadApp/Resources'
    if app.is_dir():(app/'classical-library.html').write_bytes((ROOT/'CLASSICAL.html').read_bytes())
    print('Rebuilt classical HTML and',sum(bool(x.get('ready')) for x in data['items']),'eight-bar MusicXML excerpts.')
if __name__=='__main__':main()
