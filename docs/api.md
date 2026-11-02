# API 계약

현재 API 계약은 [SORI v0.9.0](sori-api/API-CONTRACT.md)과 [OpenAPI](sori-api/openapi.json)입니다. v0.9.0은 기존 로그인·회원가입·계정 삭제에 리듬 Drills 기록 저장과 기계채점을 추가합니다. [리듬 퍼즐 안내](RHYTHM-PUZZLE.md)를 참고하세요. 아직 구현하지 않은 v0.8.0 항목(AI 채점 사용량 상한의 오류 코드)은 OpenAPI에 x-status: planned로 표시되어 있습니다. 운영 설정과 배포 점검은 [AUTH-IMPLEMENTATION.md](sori-api/AUTH-IMPLEMENTATION.md)를 참고하세요.

서버 연결 확인은 GET /api/health/, iPad 제품 API는 /api/v1/입니다. 개발 Bearer 토큰, 문제 조회, Practice 마디별 자기채점, Exam AI 평가·피드백·실패 재시도를 구현합니다. [Practice / Exam 안내](PRACTICE-EXAM.md)를 함께 확인하세요.

[개인 iPad 설치](IPAD-SETUP.md)와 [검증 상태](VALIDATION.md)를 함께 참고하세요.
