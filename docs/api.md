# API 계약

현재는 프론트엔드·백엔드 연결 확인 API만 있습니다.

## 서버 연결 확인

- Method / Path: `GET /api/health/` (마지막 `/` 포함)
- 로컬 서버: `http://localhost:8000`
- 인증: 필요 없음
- 요청 본문: 없음
- 성공: `200 OK`, `Content-Type: application/json`

```json
{"status":"ok"}
```

`POST` 등 쓰기 요청은 `405 Method Not Allowed`를 반환합니다.
서버 프로세스의 응답만 확인하며 DB 상태는 확인하지 않습니다.
앱은 10초 제한으로 요청하며 HTTP 오류·디코딩 오류·연결 실패를 화면에 표시합니다.

## 다음 API를 추가할 때

두 담당자가 경로, 메서드, 인증, 요청 JSON, 성공·실패 응답 예시를 합의하고 이 문서에 기록합니다.
제품용 인증, 데이터 모델, 필기 인식 관련 API는 미정입니다.


## SORI exam API v0.2.0

The complete versioned exam API is documented in [sori-api/API-CONTRACT.md](sori-api/API-CONTRACT.md) and [sori-api/openapi.json](sori-api/openapi.json). The iPad frontend implements all 13 operations with a separate persistent local demo. The backend health endpoint above remains available; the SORI domain endpoints still need backend implementation. See [frontend decisions](sori-frontend-decisions.md).
