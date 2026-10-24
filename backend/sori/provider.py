"""Isolated HTTP process. Credentials arrive over stdin, never command arguments or logs."""
import json
import socket
import sys
import urllib.error
import urllib.request

def main():
    config = json.load(sys.stdin)
    request = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=json.dumps(config["payload"]).encode(), headers={"Authorization": "Bearer " + config["key"], "Content-Type": "application/json", "X-Title": "SORI team 13"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=config["timeout"]) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise ValueError("response too large")
        result = {"response": json.loads(raw)}
    except urllib.error.HTTPError as error:
        retryable = error.code == 429 or error.code >= 500
        result = {"error_code": "ENGINE_UNAVAILABLE", "error_message": f"AI 서비스가 요청을 완료하지 못했습니다. (HTTP {error.code})", "retryable": retryable}
    except (socket.timeout, TimeoutError):
        result = {"error_code": "RECOGNITION_TIMEOUT", "error_message": "AI 평가 시간이 초과되었습니다.", "retryable": True}
    except (urllib.error.URLError, OSError, ValueError):
        result = {"error_code": "ENGINE_UNAVAILABLE", "error_message": "AI 서비스에 연결하거나 응답을 읽지 못했습니다.", "retryable": True}
    json.dump(result, sys.stdout, ensure_ascii=False)

if __name__ == "__main__":
    main()
