$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath 'backend/.env')) {
    throw 'backend/.env를 먼저 준비하세요. docs/IPAD-SETUP.md를 참고하세요.'
}
docker info --format '{{.ServerVersion}}'
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop을 열고 엔진이 Running이 될 때까지 기다려 주세요.' }
docker compose --env-file backend/.env up --build -d
if ($LASTEXITCODE -ne 0) { throw '서버 시작에 실패했습니다. Docker 로그를 확인해 주세요.' }
Write-Host '서버 상태: docker compose --env-file backend/.env ps'
Write-Host '계정 생성: docker compose --env-file backend/.env exec api python manage.py create_practice_user student01'
Write-Host 'iPad 서버 주소: http://<이 PC의 IPv4 주소>:8000/api/v1/'
