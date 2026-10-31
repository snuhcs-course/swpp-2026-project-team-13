"""Mirror the actual exam melodies into the standalone listening HTML."""
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT.parent/"backend/content"


def main():
    catalog = json.loads((CONTENT/"classical-catalog.json").read_text(encoding="utf-8"))
    source = json.loads((CONTENT/"source/classical/provenance.json").read_text(encoding="utf-8"))
    items = []
    for item,info in zip(catalog,source["accepted"]):
        q = item["metadata"]
        with zipfile.ZipFile(CONTENT/item["main_path"]) as z: xml=z.read("score.xml").decode("utf-8")
        score = ET.fromstring(xml); events=[]; onset=0
        for note in score.findall("part/measure/note"):
            pitch=note.find("pitch"); midi=None
            if pitch is not None:
                midi=(int(pitch.findtext("octave"))+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[pitch.findtext("step")]+int(pitch.findtext("alter","0"))
            duration=int(note.findtext("duration"))/480
            if any(t.get("type")=="stop" for t in note.findall("tie")):
                assert events[-1]["midi"]==midi; events[-1]["dur"]+=duration
            else: events.append(dict(on=onset,dur=duration,midi=midi))
            onset+=duration
        key=q["key_signature"]; pitches=[e["midi"] for e in events if e["midi"] is not None]
        identifier="classical-"+info["source_id"]
        items.append(dict(id=identifier,title=q["title"],composer=q["composer"],subtitle="앱 수록 선율",genre="클래식",source=info["source_url"],
                          credit="GTTM: Masatoshi Hamanaka, Keiji Hirata, Satoshi Tojo; musicparser mirror: Francesco Foscarin et al.",licence=source["license"],
                          kind="xml",originalMeasures=8,sourceMeasures=[str(i) for i in range(1,9)],changes=[info["normalization"]],ready=True,xml=xml,
                          file=identifier+".musicxml",events=events,total=onset,low=min(pitches),high=max(pitches),noteCount=len(pitches),
                          beats=q["time_signature"]["numerator"],unit=q["time_signature"]["denominator"],keyLabel=key["tonic"].replace("b","♭").replace("#","♯")+("단조" if key["mode"]=="minor" else "장조")))
    data=dict(date="2026-11-01",items=items,sources=[dict(title="GTTM Database",url="https://gttm.jp/gttm/database/"),dict(title="MusicXML 미러와 이용 조건",url="https://github.com/fosfrancesco/musicparser")])
    (ROOT/"library-data.json").write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    keep={x["file"] for x in items}
    for file in (ROOT/"xml").glob("classical-*.musicxml"):
        assert file.resolve().is_relative_to((ROOT/"xml").resolve())
        if file.name not in keep: file.unlink()
    import render_library
    render_library.main()


if __name__ == "__main__":
    main()
