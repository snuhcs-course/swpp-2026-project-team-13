# API 계약

현재 API 계약은 [SORI v0.8.0](sori-api/API-CONTRACT.md)과 [OpenAPI](sori-api/openapi.json)입니다. 구현은 v0.7.0과 v0.8.0의 회원가입·계정 삭제까지이며, 아직 구현하지 않은 v0.8.0 항목(AI 채점 사용량 상한의 오류 코드)은 OpenAPI에 x-status: planned로 표시되어 있습니다. 계정·사용량 제한의 서버 구현, 현재 배포 구성(개인 Windows 데스크톱과 Cloudflare Tunnel), 운영 설정, 배포 점검과 검증 항목은 [AUTH-IMPLEMENTATION.md](sori-api/AUTH-IMPLEMENTATION.md)를 참고하세요.

서버 연결 확인은 GET /api/health/, iPad 제품 API는 /api/v1/입니다. 개발 Bearer 토큰, 세 문제, 응시·이미지 업로드·제출·AI 평가 작업·결과 조회·실패 재시도를 구현합니다.

[개인 iPad 설치](IPAD-SETUP.md)와 [검증 상태](VALIDATION.md)를 함께 참고하세요.
