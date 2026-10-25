"""Generate current API examples from the same content and timing policy as the backend."""
import copy
import importlib.util
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("playback",ROOT/"backend/sori/playback.py")
playback=importlib.util.module_from_spec(spec);spec.loader.exec_module(playback)
EXAMPLES=ROOT/"docs/sori-api/examples"
catalog=json.loads((ROOT/"backend/content/catalog.json").read_text(encoding="utf-8"))
questions=[playback.timed_question(item["metadata"]) for item in catalog]
def save(name,value):
    (EXAMPLES/(name+".json")).write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
for index,q in enumerate(questions,1):
    save(f"question-excerpt-{index}",q)
summary_keys=("id","version","title","source","key_signature","time_signature","measure_count","recommended_duration_seconds","tempo")
save("questions-v0.5",{"count":3,"next":None,"previous":None,"results":[{key:q[key] for key in summary_keys} for q in questions]})
attempt=json.loads((EXAMPLES/"attempt-ready-v3.json").read_text(encoding="utf-8"))
attempt["question"]=questions[0];attempt["playback_plan"]=playback.make_playback_plan(questions[0])
save("attempt-ready-v4",attempt)
print("Updated current v0.5 examples; v2/v3 attempt fixtures preserved.")
