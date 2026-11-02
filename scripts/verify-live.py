"""Run from the user's normal PowerShell. HTTP checks; optional real paid AI call.

The default checks never submit for grading. --with-ai submits a blank template once,
so it verifies real transport/JSON/worker behavior, not handwriting-recognition accuracy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "backend" / ".local"

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8000")
    parser.add_argument("--with-ai", action="store_true")
    options=parser.parse_args()
    base=options.base.rstrip("/")
    origin=urllib.parse.urlparse(base)
    if origin.scheme not in ("http","https") or origin.username or origin.password or origin.path:
        raise ValueError("Use an HTTP(S) origin without a path")
    LOCAL.mkdir(exist_ok=True)
    report={"base":base,"checks":[],"ai_requested":options.with_ai,"ai_result":None}
    report_path=LOCAL / "live-checks.json"
    def save():
        report_path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
    def check(name, condition):
        report["checks"].append({"name":name,"passed":bool(condition)})
        save()
        if not condition:
            raise RuntimeError("Check failed: "+name)
        print("PASS "+name,flush=True)
    token_text=(LOCAL / "connection.txt").read_text(encoding="utf-8")
    token=re.search(r"개발 토큰:\s*([a-f0-9]{40})",token_text,re.I).group(1)
    def request(path, method="GET", payload=None, key=None, authenticated=True, accept="application/json", content_type=None):
        url=path if path.startswith("http") else base+path
        target=urllib.parse.urlparse(url)
        if (target.scheme,target.netloc)!=(origin.scheme,origin.netloc):
            raise RuntimeError("Cross-origin resource refused")
        headers={"Accept":accept}
        if authenticated:
            headers["Authorization"]="Bearer "+token
        if key:
            headers["Idempotency-Key"]=key
        if isinstance(payload,dict):
            payload=json.dumps(payload).encode();content_type="application/json"
        if content_type:
            headers["Content-Type"]=content_type
        req=urllib.request.Request(url,data=payload,headers=headers,method=method)
        with urllib.request.urlopen(req,timeout=60) as response:
            data=response.read(11*1024*1024)
            if accept=="application/json":
                data=json.loads(data)
            return response.status,data
    try:
        status,health=request("/api/health/",authenticated=False)
        check("health",status==200 and health=={"status":"ok"})
        _,me=request("/api/v1/me/")
        _,page=request("/api/v1/questions/")
        expected=json.loads((ROOT / "backend/content/catalog.json").read_text(encoding="utf-8"))
        expected.extend(json.loads((ROOT / "backend/content/additional-practice-catalog.json").read_text(encoding="utf-8")))
        check("full practice catalog",page["count"]==len(expected))
        summaries=list(page["results"])
        while page["next"]:
            _,page=request(page["next"])
            summaries.extend(page["results"])
        check("all catalog pages",len(summaries)==len(expected) and len({q["id"] for q in summaries})==len(expected))
        questions=[]
        for summary in summaries:
            _,q=request("/api/v1/questions/"+summary["id"]+"/")
            questions.append(q)
            for kind,asset in q["score_assets"].items():
                status,data=request(asset["url"],accept="application/vnd.recordare.musicxml")
                check(q["title"]+" "+kind,status==200 and len(data)==asset["size_bytes"] and hashlib.sha256(data).hexdigest()==asset["sha256"])
            status,png=request(q["sheet_layout"]["template_png_url"],authenticated=False,accept="image/png")
            check(q["title"]+" template",status==200 and hashlib.sha256(png).hexdigest()==q["sheet_layout"]["template_sha256"])
        q=questions[2]
        state_path=LOCAL / "live-probe-state.json"
        state=json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
        if state.get("user_id")!=me["id"] or state.get("base")!=base:
            state={"base":base,"user_id":me["id"],"create_key":str(uuid.uuid4()),"upload_key":str(uuid.uuid4()),"submit_key":str(uuid.uuid4()),"client_answer_id":str(uuid.uuid4())}
        def save_state():
            state_path.write_text(json.dumps(state,indent=2),encoding="utf-8")
            state_path.chmod(0o600)
        save_state()
        _,attempt=request("/api/v1/attempts/","POST",{"question_id":q["id"],"question_version":q["version"]},state["create_key"])
        path="/api/v1/attempts/"+attempt["id"]
        _,attempt=request(path+"/")
        state["attempt_id"]=attempt["id"];save_state()
        if attempt["status"]!="submitted":
            _,attempt=request(path+"/start/","POST")
            _,same=request(path+"/start/","POST")
            check("start is idempotent",attempt["started_at"]==same["started_at"])
            png=(ROOT/"backend"/"content"/"sheets"/(q["sheet_layout"]["id"]+".png")).read_bytes()
            boundary="sori-probe-"+state["upload_key"]
            fields={"client_answer_id":state["client_answer_id"],"answer_format_version":"1","sheet_layout_id":q["sheet_layout"]["id"]}
            chunks=[]
            for name,value in fields.items():
                chunks.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
            chunks.extend([f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="answer.png"\r\nContent-Type: image/png\r\n\r\n'.encode(),png,f'\r\n--{boundary}--\r\n'.encode()])
            multipart=b"".join(chunks)
            _,answer=request(path+"/answers/","POST",multipart,state["upload_key"],content_type="multipart/form-data; boundary="+boundary)
            check("uploaded bytes unchanged",answer["sha256"]==hashlib.sha256(png).hexdigest() and answer["size_bytes"]==len(png))
            _,same=request(path+"/answers/","POST",multipart,state["upload_key"],content_type="multipart/form-data; boundary="+boundary)
            check("upload receipt is idempotent",same["id"]==answer["id"])
            _,returned=request(answer["image_url"],accept="image/png")
            check("private PNG download",returned==png)
            state["answer_id"]=answer["id"];save_state()
        if options.with_ai:
            env=(ROOT/"backend"/".env").read_text(encoding="utf-8")
            configured=re.search(r"^OPENROUTER_API_KEY=(.+)$",env,re.M)
            if not configured or not configured.group(1).strip().strip("\"'"):
                raise RuntimeError("Set OPENROUTER_API_KEY in backend/.env and rerun docker compose up -d first.")
            _,grading=request(path+"/submit/","POST",{"answer_id":state["answer_id"]},state["submit_key"])
            check("submitted answer pinned",grading["answer_id"]==state["answer_id"])
            deadline=time.monotonic()+300
            while grading["status"] in ("queued","processing") and time.monotonic()<deadline:
                print("AI "+grading["status"],flush=True)
                time.sleep(2)
                _,grading=request(path+"/result/")
            report["ai_result"]={"status":grading["status"],"score":grading["score"],"failure":grading["failure"],"feedback":grading["feedback"],"job_id":grading["job_id"]}
            save()
            check("real AI blank-answer result",grading["status"]=="completed" and grading["score"]==0)
            check("real Korean feedback",bool(grading["feedback"]["summary"]))
        report["completed"]=True
        save()
        print("Report saved to "+str(report_path),flush=True)
    except Exception as error:
        report["completed"]=False
        # Do not record exception request headers or API credentials.
        report["failure_type"]=type(error).__name__
        save()
        print(str(error),file=sys.stderr,flush=True)
        raise SystemExit(1)

if __name__=="__main__":
    main()
