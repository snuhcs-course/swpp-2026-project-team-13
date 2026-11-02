# SORI 계정·사용량 제한 구현 및 운영 노트

[API-CONTRACT.md](API-CONTRACT.md)는 앱이 관찰할 수 있는 동작(요청·응답·상태 코드·헤더·오류 코드)을 정의합니다. 이 문서는 그 동작을 만들기 위한 서버·앱 내부 구현, 현재 배포 구성, 운영 설정, 배포 점검과 검증 항목을 담습니다. 두 문서가 다르면 API 계약을 따르고 이 문서를 고칩니다.

대상은 v0.7.0 로그인과 v0.8.0 회원가입, 계정 삭제, 클라이언트 IP 판정, AI 채점 사용량 상한, 현재 배포 구성입니다. v0.8.0 중 회원가입, 계정 삭제, 클라이언트 IP 판정, 프록시 경유 요청 처리와 gunicorn 실행은 구현했습니다. AI 채점 사용량 상한(설정 검증 제외), compose의 cloudflared 구성과 api 포트 제한은 아직 구현 전입니다.

## 배포 구성

현재 범위는 서비스 운영이 아닌 배포 테스트입니다. 서버는 개발자의 개인 Windows 데스크톱에서 Docker Desktop과 Compose(db, api, worker, cloudflared)로 실행하고 Cloudflare Tunnel로 공개합니다. 앱은 Mac의 Xcode로 테스트 기기 두 대에 직접 설치하며 TestFlight·App Store로 배포하지 않습니다. 이 절과 [배포 점검 항목](#배포-점검-항목), [배포 테스트](#배포-테스트)는 이 구성만 다룹니다. 다른 서버로 옮길 때는 [서비스 전환 전에 다시 볼 항목](#서비스-전환-전에-다시-볼-항목)을 확인합니다.

이 문서의 docker compose 명령은 저장소 루트에서 실행합니다. compose.yaml이 backend/.env의 값을 사용하므로 scripts/start-windows.ps1과 같이 `--env-file backend/.env`를 붙입니다.

- cloudflared는 Windows 호스트나 Windows 서비스가 아닌 compose 서비스로 실행하고, 고정 주소를 가진 별도 네트워크에 둡니다. 이 주소만 TRUSTED_PROXIES에 넣습니다. Docker Desktop은 포트 포워딩한 연결의 원래 IP를 보존하지 않을 수 있어, 호스트에서 실행하면 터널 요청과 LAN 직접 요청을 구별하지 못할 수 있습니다.
- cloudflared에는 `tunnel` 프로필을 지정합니다. scripts/start-windows.ps1의 `up`은 프로필이 없는 서비스만 시작하므로 서버를 켜도 터널은 열리지 않습니다.
- 터널은 테스트하는 동안만 실행합니다. `docker compose --env-file backend/.env --profile tunnel up -d cloudflared`로 열고 `docker compose --env-file backend/.env --profile tunnel stop cloudflared`로 닫습니다.
- 도메인 없이 시작할 때는 Quick Tunnel을 사용합니다. 시작할 때마다 *.trycloudflare.com 주소가 바뀌며 `docker compose --env-file backend/.env --profile tunnel logs cloudflared`에서 확인합니다. 주소가 바뀌면 앱에서는 서버 변경이므로 기기마다 서버 주소를 다시 입력하고 로그인하며, 이전 origin의 로컬 기록은 연결되지 않습니다. Cloudflare에 등록한 도메인이 있으면 이름 있는 터널로 주소를 고정합니다.
- api 포트는 LAN의 Debug 빌드로 함께 테스트할 때만 `8000:8000`으로 열고, 그 외에는 `127.0.0.1:8000:8000`으로 제한합니다. LAN에 열면 같은 네트워크의 누구나 관리 화면에 접근할 수 있으므로 학교·카페 등 공용 Wi-Fi에서는 열지 않습니다.
- boot.py는 마이그레이션과 문제 시드 후 runserver 대신 gunicorn을 실행합니다(`gunicorn config.wsgi:application --bind 0.0.0.0:$PORT --workers 2 --threads 4`). 포트는 PORT 환경 변수로 받고 기본값은 8000입니다. runserver는 운영용 서버가 아니고 길이 정보 없는 요청 본문을 읽지 못할 수 있습니다. 시도 제한은 DB에 저장하므로 프로세스가 여러 개여도 공유됩니다. gunicorn은 정적 파일을 제공하지 않으므로 로컬 관리 화면에 스타일이 적용되지 않을 수 있으며, 현재 범위에서는 수용합니다.

```yaml
services:
  api:
    ports:
      - "127.0.0.1:8000:8000"
    networks: [default, edge]
  cloudflared:
    image: cloudflare/cloudflared:<고정 버전>
    profiles: ["tunnel"]
    command: ["tunnel", "--no-autoupdate", "--url", "http://api:8000"]
    networks:
      edge:
        ipv4_address: 172.30.0.10
    depends_on:
      api:
        condition: service_healthy
networks:
  edge:
    ipam:
      config:
        - subnet: 172.30.0.0/24
```

이 예시에서는 TRUSTED_PROXIES=172.30.0.10/32, CLIENT_IP_HEADER=CF-Connecting-IP입니다. 이름 있는 터널은 command를 `tunnel --no-autoupdate run`으로 바꾸고 TUNNEL_TOKEN을 backend/.env가 아닌 별도 비공개 env 파일로 전달합니다.

## 운영 전제와 수용한 위험

- 이 절의 판단은 현재 테스트 규모에서만 유효합니다. 실제 사용자를 받기 전에 [서비스 전환 전에 다시 볼 항목](#서비스-전환-전에-다시-볼-항목)을 다시 정합니다.
- 사용자는 개발자와 테스트 기기 두 대입니다. 앱 배포 범위는 서버 접근 범위를 제한하지 않습니다. 터널이 열린 동안 주소를 아는 누구나 API를 호출할 수 있고, 주소는 앱 설정·문서·공유 링크로 노출될 수 있으므로 비밀로 간주하지 않습니다.
- 이에 대한 대응은 터널을 테스트 중에만 실행, SIGNUP_ENABLED를 가입 테스트 중에만 true로 설정, 관리 화면을 터널로 제공하지 않음, DJANGO_DEBUG=false, AI 두 상한과 OpenRouter API 키의 지출 한도입니다.
- 터널이 열린 동안 주소를 알게 된 사람이 가입해 AI_MAX_JOBS_PER_DAY를 소진하면 모든 사용자의 채점이 대기하는 위험을 수용합니다. 비용은 AI 두 상한과 OpenRouter 지출 한도로 막습니다. 서버 전체 가입 상한, 가입 코드(초대 코드), 가입 계정과 관리자 계정의 AI 한도 분리는 이번 범위에 두지 않습니다. 외부 테스터를 받기 전에 가입 코드를 추가합니다.
- Cloudflare 엣지에서 TLS가 종료되므로 Cloudflare는 비밀번호와 토큰을 볼 수 있습니다. MVP에서 수용합니다.
- 계정 삭제는 비밀번호를 다시 묻지 않으므로, 유효한 토큰만 있으면 계정과 학습 기록을 영구 삭제할 수 있습니다. 토큰은 만료되지 않고 기기 간에 공유됩니다. 테스트 계정만 있는 현재 범위에서 수용합니다. 관리자 계정은 앱에서 삭제할 수 없습니다.
- Windows 데스크톱이 꺼지거나 절전 상태이거나 업데이트로 재시작하면 서비스가 중단됩니다. 앱은 이를 네트워크 오류·5xx로 처리하고 인증 상태를 바꾸지 않습니다.
- 개인정보를 저장하지 않습니다. 서버 요청 로그와 시도 제한 저장소에는 클라이언트 IP 원문을 남기지 않습니다([클라이언트 IP 판정](#클라이언트-ip-판정)). Cloudflare는 자체적으로 방문자 IP를 처리할 수 있습니다.

### 남용 대응 절차

가입만 끄면 이미 만들어진 계정은 계속 채점을 요청할 수 있으므로 필요한 단계를 함께 수행합니다.

1. `docker compose --env-file backend/.env --profile tunnel stop cloudflared`로 터널을 닫습니다. 외부 접근이 즉시 모두 차단되며 로컬·LAN 접근은 유지됩니다.
2. backend/.env에서 SIGNUP_ENABLED=false로 바꾸고 `docker compose --env-file backend/.env up -d`로 컨테이너를 다시 만듭니다. 기존 계정의 로그인·채점·계정 삭제는 유지됩니다.
3. 남용 계정을 비활성화합니다. Django admin의 사용자 변경 화면에서 "활성" 체크를 해제하면, 0002_login 마이그레이션의 sori_credentials_changed 트리거가 같은 트랜잭션에서 토큰을 폐기합니다. 이후 로그인과 Bearer 인증이 모두 거절되므로 채점을 요청할 수 없습니다. 여러 계정은 Django shell에서 QuerySet.update(is_active=False)로 처리해도 같은 트리거가 적용됩니다.

Django admin의 사용자 삭제는 응시의 PROTECT 참조 때문에 실패하므로, 계정을 지우려면 [delete_practice_user](#계정-삭제-절차)를 사용합니다.

### 계정 생성 경로와 비밀번호 재설정 정책

UserProfile에 내부 필드 created_via(admin 또는 signup)를 둡니다. API 응답에는 포함하지 않습니다. 회원가입은 signup, create_practice_user와 issue_dev_token은 admin으로 기록하며, 마이그레이션은 기존 프로필을 admin으로 채웁니다.

create_practice_user는 기존 계정의 비밀번호를 재설정할 수 있지만 created_via=signup인 계정이면 비밀번호와 표시 이름을 바꾸지 않고 오류로 안내합니다. 가입 계정은 연락처가 없어 요청자가 소유자인지 확인할 수 없고, 확인 없는 재설정은 다른 사람이 계정을 가로채는 통로가 되기 때문입니다. Django admin의 비밀번호 변경과 changepassword 명령은 막지 않으며, 가입 계정에 사용하지 않는 것을 운영 규칙으로 둡니다.

### 테스트 종료 정리

테스트가 끝나면 Django admin의 UserProfile 목록에서 created_via=signup인 계정을 확인해 delete_practice_user로 하나씩 삭제합니다. 비밀번호를 잊어 앱에서 삭제하지 못한 계정도 이때 함께 정리합니다. 대상이 적으므로 일괄 삭제 옵션은 두지 않습니다. UserProfile 관리 화면에는 created_via 목록 필터를 추가합니다.

## 운영 설정과 한도

v0.8.0이 추가하는 서버 설정은 아래 환경 변수로 조정합니다. 기본값은 이 표에서만 정의하며, API 계약은 설정 이름으로만 참조합니다. 집계 구간은 코드에 고정하고 횟수만 설정으로 바꿉니다.

| 설정 | 기본값 | 단위·집계 구간 | 적용 대상 |
|---|---|---|---|
| SIGNUP_ENABLED | false | – | 회원가입, 가입 가능 여부 |
| LOGIN_MAX_REQUESTS_PER_IP | 30 | IP별 로그인 요청 수, 최근 5분 | 로그인(v0.7.0의 고정값 30을 설정으로 전환) |
| SIGNUP_MAX_REQUESTS_PER_IP | 30 | IP별 가입 요청 수, 최근 5분 | 회원가입 |
| SIGNUP_MAX_SUCCESSES_PER_IP | 20 | IP별 가입 성공 수, 최근 24시간 | 회원가입 |
| AI_MAX_JOBS_PER_USER_PER_DAY | 없음(SIGNUP_ENABLED=true이면 필수) | 사용자별 채점 작업 수, 최근 24시간 | submit, grading-retries |
| AI_MAX_JOBS_PER_DAY | 없음(SIGNUP_ENABLED=true이면 필수) | 서버 전체 채점 작업 수, 최근 24시간 | submit, grading-retries |
| AI_MAX_JOBS_PER_ATTEMPT | 3(기존) | 응시별 채점 작업 수, 기간 없음 | grading-retries |
| TRUSTED_PROXIES | 빈 목록 | 쉼표로 구분한 CIDR 목록. 현재 배포에서는 cloudflared 컨테이너 주소/32 | [클라이언트 IP 판정](#클라이언트-ip-판정), [프록시 경유 요청](#공개-origin과-프록시-경유-요청) |
| CLIENT_IP_HEADER | 없음 | 신뢰 프록시가 접속 IP 하나를 담아 보내는 헤더 이름. 현재 배포에서는 CF-Connecting-IP | [클라이언트 IP 판정](#클라이언트-ip-판정) |
| PORT | 8000 | api 서버가 수신할 포트 | boot.py |

가입 IP 한도의 기본값은 테스트 중 가입과 계정 삭제를 반복해도 막히지 않으면서, 터널 주소를 알게 된 외부인이 하루에 만들 수 있는 계정 수를 제한하도록 정했습니다. 계정 삭제는 가입 성공 집계를 줄이지 않으므로, 가입 테스트를 하루 20회 넘게 반복하면 값을 올립니다. 로그인 아이디별 실패 제한(5분·5회)은 계정 보호용이므로 설정으로 바꾸지 않습니다.

- 횟수 설정은 1 이상의 정수입니다. 정수가 아니거나 1 미만이면 서버가 설정 오류(ImproperlyConfigured)로 시작하지 않습니다. 빈 값은 설정하지 않은 것으로 보며, 기본값이 있는 항목은 기본값을 사용합니다.
- SIGNUP_ENABLED는 DJANGO_DEBUG와 같이 대소문자를 무시한 "true"만 참이며 그 외 값은 거짓입니다. TRUSTED_PROXIES에 해석할 수 없는 항목이 있거나, TRUSTED_PROXIES와 CLIENT_IP_HEADER 중 하나만 설정되어 있으면 시작하지 않습니다.
- SIGNUP_ENABLED=true인데 AI_MAX_JOBS_PER_USER_PER_DAY나 AI_MAX_JOBS_PER_DAY가 없거나 1 미만이면 설정 오류로 시작하지 않습니다. OpenRouter API 키의 지출 한도는 서버가 확인할 수 없으므로 [배포 점검 항목](#배포-점검-항목)으로 확인합니다.
- 설정은 서버 시작 시 읽습니다. backend/.env를 수정한 뒤 `docker compose --env-file backend/.env up -d`로 컨테이너를 다시 만들어 적용합니다. `docker compose restart`는 env_file을 다시 읽지 않으므로 사용하지 않습니다. 적용된 값은 `docker compose --env-file backend/.env exec api python manage.py diffsettings`로 확인합니다.
- 한도를 올리면 다음 요청부터 바로 적용됩니다. 낮추면 이미 집계된 기록이 구간에서 빠져 집계 수가 새 한도 아래로 내려갈 때까지 제한됩니다.
- 공통 대기 시간 규칙: 최근 구간의 집계 수가 한도 이상이면, (집계 수 − 한도 + 1)번째로 오래된 기록이 구간에서 빠질 때까지 남은 시간을 대기 시간으로 사용합니다. 집계 수가 한도와 같으면 가장 오래된 기록이 기준입니다. 로그인 IP 제한, 가입 요청·가입 성공 한도와 두 AI 상한에 적용합니다.
- AI 두 상한은 기본값 없이 운영자가 정합니다. AI_MAX_JOBS_PER_DAY × 작업 1건의 최대 비용이 하루 예산 이하가 되도록 정하고, OpenRouter API 키의 지출 한도도 같은 예산 이하로 둡니다. 작업 1건의 최대 비용은 입력 이미지·프롬프트 토큰과 AI_MAX_OUTPUT_TOKENS에 모델 단가를 곱해 계산합니다.
- 예를 들어 테스트 기기 두 대로 하루 10회씩 채점받으려면 AI_MAX_JOBS_PER_USER_PER_DAY=10, AI_MAX_JOBS_PER_DAY=30으로 둡니다. 30 × 작업 1건의 최대 비용이 하루 예산을 넘으면 두 값을 낮춥니다.
- AI_MAX_JOBS_PER_DAY는 가입 계정과 관리자가 만든 계정이 함께 사용합니다. 소진되면 모든 사용자가 대기하며, 이 버전은 비용 상한을 가용성보다 우선하는 것을 수용한 위험으로 둡니다. 대응은 [남용 대응 절차](#남용-대응-절차)를 따릅니다.
- 배포에는 기존 설정 DJANGO_DEBUG=false, 기본값이 아닌 DJANGO_SECRET_KEY, 터널 호스트를 포함한 DJANGO_ALLOWED_HOSTS가 필요합니다. DJANGO_ALLOWED_HOSTS는 기본 목록을 대체하므로 기존 localhost,127.0.0.1,[::1]을 유지한 채 추가합니다. localhost가 빠지면 compose의 api 헬스체크가 실패해 worker와 cloudflared가 시작되지 않습니다. Quick Tunnel은 `.trycloudflare.com`(앞의 점은 하위 도메인 전체)을, 이름 있는 터널은 그 호스트 이름을 추가합니다. LAN 테스트를 함께 하면 Windows 데스크톱의 현재 LAN IPv4도 추가합니다.
- 구현 시 backend/.env.example에 위 설정을 모두 단위·집계 구간 주석과 함께 추가합니다. AI 두 상한은 값을 비운 채 위 계산식을 주석으로 둡니다.

## 배포 점검 항목

터널을 열기 전에 확인합니다.

- OpenRouter API 키의 지출 한도가 하루 예산 이하로 설정되어 있는지 확인합니다.
- SIGNUP_ENABLED=true로 켜기 전에 AI 두 상한을 정했는지 확인합니다. 가입 테스트를 하지 않을 때는 false로 둡니다.
- Docker Desktop이 실행 중이고, 테스트하는 동안 Windows 절전이 꺼져 있으며, 업데이트 재시작이 예약되어 있지 않은지 확인합니다.
- DJANGO_DEBUG=false, 고유한 DJANGO_SECRET_KEY, DJANGO_ALLOWED_HOSTS의 터널 호스트와 localhost를 확인합니다. LAN으로 테스트하면 현재 LAN IPv4도 들어 있는지 확인합니다. settings.py는 DEBUG=false에서 예시 키를 거부합니다.
- cloudflared가 compose의 edge 네트워크에서 고정 주소로 실행되고, 그 주소가 TRUSTED_PROXIES와 같으며, CLIENT_IP_HEADER=CF-Connecting-IP인지 확인합니다. 다르면 모든 터널 요청이 하나의 IP로 집계되고 관리 화면 차단도 동작하지 않습니다.
- api 포트가 의도대로 열려 있는지 확인합니다. LAN 테스트를 하지 않으면 127.0.0.1에만 열려 있어야 합니다.
- issue_dev_token으로 만든 개발 토큰은 만료되지 않고 터널로도 사용할 수 있습니다. 쓰지 않는 개발 토큰은 Django admin의 토큰 목록에서 삭제합니다.
- 이름 있는 터널은 Cloudflare 대시보드에서 Bot Fight Mode를 끄고 /api/ 경로에 챌린지가 적용되지 않는지 확인합니다. 챌린지는 앱 요청에 HTML 응답을 반환합니다. Quick Tunnel에는 해당 설정이 없습니다.
- v0.8.0 배포 전에 대소문자만 다른 기존 계정이 없는지 아래 조회로 확인합니다. 결과가 비어 있어야 합니다. 조회 결과가 있으면 [아이디 대소문자 무시 유일성](#아이디-대소문자-무시-유일성)의 마이그레이션이 중단됩니다.

  ```
  docker compose --env-file backend/.env exec db psql -U sori -d sori -c "SELECT lower(username), array_agg(username) FROM auth_user GROUP BY 1 HAVING count(*) > 1;"
  ```

터널을 연 뒤에는 [배포 테스트](#배포-테스트)를 수행하고, 테스트가 끝나면 터널을 닫고 SIGNUP_ENABLED=false로 되돌립니다.

## 서비스 전환 전에 다시 볼 항목

현재 문서는 테스트 범위만 다룹니다. 이전 대상별 절차서는 대상이 정해진 뒤에 작성하며, 실제 사용자를 받기 전에 아래 항목을 다시 정합니다.

- 가입 남용: 가입 코드를 추가하고, SIGNUP_ENABLED를 상시 켜도 되는지 정합니다.
- 시도 제한: 사용 인원과 공유 IP를 기준으로 로그인·가입 IP 한도를 다시 정합니다. 현재 기본값은 두 기기 테스트 기준입니다.
- 프록시: 새 환경의 TRUSTED_PROXIES와 CLIENT_IP_HEADER를 다시 검증합니다. 그 환경에 값이 IP 하나인 신뢰 헤더가 없으면 판정 규칙을 추가합니다. SECURE_PROXY_SSL_HEADER의 신뢰 범위도 다시 확인합니다.
- 답안 파일: 지금은 api와 worker가 같은 볼륨을 공유합니다. 디스크를 서비스 간에 공유할 수 없는 환경(Render 등)에서는 객체 저장소가 필요합니다. 파일 접근은 Django 저장소 API로만 유지합니다.
- 실행 구조: 시작 시 마이그레이션(boot.py), 재배포 중 동작, 다중 인스턴스 여부, worker 실행 방식과 비용을 정합니다.
- 관리 화면: 프록시 경유 요청은 관리 화면에 접근할 수 없으므로, 새 환경의 관리 접근 경로를 정합니다.
- 서버 주소: 앱은 토큰과 로컬 기록을 origin별로 묶으므로, 실제 사용자를 받기 전에 고정 도메인을 정합니다.
- 가용성과 데이터: 백업, 복구, 서버 상시 운영, 동시 사용 부하를 검증합니다. 테스트 데이터는 이전하지 않는 것을 기본으로 합니다.
- 계정 정책: 만료 없는 공유 토큰, 비밀번호 복구 불가 정책, 비밀번호 재확인 없는 계정 삭제를 유지할지 정합니다.
- 앱 배포: TestFlight·App Store로 배포하면 Apple 심사 요건과 Release 빌드 동작을 다시 확인합니다.

## 서버 구현 노트

### 공개 origin과 프록시 경유 요청

- settings.py에 SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")를 둡니다. 프록시가 X-Forwarded-Proto: https를 붙이면 build_absolute_uri()가 https URL을 만들고, 헤더가 없는 직접 요청은 http URL을 받습니다. Cloudflare는 문서에서 클라이언트가 보낸 이 헤더 값을 덮어쓴다고 설명합니다. 공개 origin을 설정값으로 고정하지 않는 이유는 Quick Tunnel 주소가 바뀌어도, LAN과 터널을 함께 써도 각 요청에 맞는 origin을 돌려주기 위함입니다.
- Django는 이 헤더를 보낸 쪽과 무관하게 신뢰합니다. 위조로 바뀌는 것은 그 요청의 응답 URL scheme과 request.is_secure()뿐이므로 현재 범위에서 수용합니다. Secure 쿠키 등 is_secure()에 의존하는 설정을 추가할 때 다시 검토합니다.
- 절대 URL의 호스트는 Host 헤더에서 나옵니다. cloudflared에 httpHostHeader 옵션을 설정하지 않으며, 공개 호스트 이름이 전달되는지는 [배포 테스트](#배포-테스트) 1번의 자산 URL로 확인합니다.
- 프록시 경유 요청은 REMOTE_ADDR이 TRUSTED_PROXIES에 속하는 요청입니다. CLIENT_IP_HEADER 헤더의 유무로 판정하지 않습니다.
- RequestMiddleware 다음에 경로 제한을 둡니다. 프록시 경유 요청의 경로가 /api/ 또는 /assets/로 시작하지 않으면 404를 반환합니다. Django 관리 화면은 프록시를 거치지 않는 `http://localhost:8000/admin/`(또는 LAN 주소)으로만 사용합니다. 이름 있는 터널은 ingress 규칙의 path에도 `^/(api|assets)/`를 지정해 이중으로 막을 수 있습니다.

### 회원가입 처리

입력 검증과 대소문자 무시 중복 사전 확인을 통과하면, 하나의 DB 트랜잭션에서 아래 순서로 처리해 일부만 생성된 상태를 남기지 않습니다.

1. 요청 IP의 가입 성공 집계 행을 잠그고 성공 한도를 다시 확인합니다. 집계는 로그인과 같은 LoginThrottle 모델에 별도 종류("signup-success")의 키로 두고 locked_throttle로 잠급니다. 한도에 도달했으면 입력이 유효하더라도 429를 반환하고 아무것도 생성하지 않습니다.
2. 사용 가능한 비밀번호를 가진 활성 사용자를 생성합니다. is_staff와 is_superuser는 false이며 email, first_name, last_name은 빈 값입니다. 유일 인덱스·제약 위반은 409 USERNAME_TAKEN입니다.
3. 요청의 display_name과 learning_goal, created_via=signup을 가진 UserProfile을 생성합니다.
4. 사용자의 DRF Token을 생성합니다.
5. 해당 아이디의 로그인 실패 횟수와 차단 상태를 초기화합니다. 가입 전에 같은 아이디로 발생한 로그인 실패가 새 계정의 로그인을 막지 않게 하기 위함입니다.
6. 요청 IP의 가입 성공 집계에 이번 성공을 기록하고 커밋합니다.

- 요청 앞부분의 성공 한도 확인은 빠른 거절을 위한 사전 확인이며, 최종 판정은 1단계에서 집계를 잠근 상태로 다시 수행합니다. 따라서 같은 IP의 동시 요청도 한도를 넘어 계정을 생성하지 않습니다.
- 비밀번호 해시는 트랜잭션 전에 make_password로 계산해 둡니다. 집계 잠금을 쥔 채 해시를 계산하면 같은 IP의 가입 요청이 해시 시간만큼 줄을 서기 때문입니다.
- 비밀번호 정책은 저장하지 않은 User(username=...) 객체와 함께 validate_password로 검사해 아이디 유사성을 확인합니다. username이 형식 규칙을 통과하지 못했으면 user 없이 검사합니다. UserAttributeSimilarityValidator는 auth_user의 속성만 비교하므로 display_name과의 유사성은 검사하지 않습니다.
- 동시 요청에서 발생한 유일 인덱스·제약 위반도 409로 변환합니다. 같은 아이디의 동시 가입은 하나만 201이고 나머지는 409입니다.
- 회원가입 요청 집계는 로그인 집계와 다른 종류의 키를 사용합니다.

### 아이디 대소문자 무시 유일성

- auth_user의 lower(username)에 DB 유일 인덱스를 두어, 가입·Django admin·관리 명령 등 모든 계정 생성·아이디 변경 경로에서 대소문자만 다른 계정을 허용하지 않습니다.
- 대소문자 무시 비교는 모든 경로에서 인덱스와 같은 PostgreSQL lower(username) 식을 사용합니다. 가입의 사전 확인, 마이그레이션의 사전 조회, create_practice_user가 여기에 해당하며, username__iexact(UPPER 비교)나 Python의 lower()·casefold()로 대신하지 않습니다.
- Django admin의 사용자 추가 폼은 자체 대소문자 검사를 하지만 사용자 변경 폼은 아이디 변경을 검사하지 않습니다. 변경 폼에도 같은 lower(username) 기준의 검사를 추가해 인덱스 위반의 500 대신 폼 오류로 안내합니다.
- contrib User 모델에는 Meta 인덱스를 추가할 수 없으므로 마이그레이션은 sori 앱의 RunSQL로 작성하고, auth 앱의 마지막 마이그레이션에 의존하며, 되돌리는 SQL을 함께 둡니다. 적용 전에 같은 lower(username) 식으로 대소문자만 다른 기존 계정을 조회해, 있으면 계정 목록과 "admin에서 한쪽 아이디를 바꾼 뒤 다시 시작하세요"라는 해결 방법을 함께 출력하고 중단합니다.
- create_practice_user는 대소문자만 다른 기존 계정이 있으면 새 계정을 만들지 않고 오류로 안내합니다.
- boot.py가 시작 시 마이그레이션을 실행하므로, 이 마이그레이션이 중단되면 api 컨테이너가 재시작을 반복하고 worker도 시작하지 않습니다. 배포 전 조회는 [배포 점검 항목](#배포-점검-항목)에 있습니다.

### 입력 검증 구현

- 문자열 길이는 Python len()(유니코드 코드 포인트 수)으로 셉니다.
- username은 re.fullmatch 또는 \A…\Z 앵커로 검사하고 ^…$로 검사하지 않습니다. Python의 $는 끝의 줄바꿈 앞에서도 일치하므로 student01\n이 통과할 수 있기 때문입니다. OpenAPI의 pattern은 ECMA-262 규칙이므로 ^[a-z][a-z0-9_]{3,19}$로 표기합니다.
- display_name의 앞뒤 공백은 Unicode White_Space 속성 문자입니다. Python str.isspace()는 U+001C–U+001F에서도 참이라 White_Space와 다르지만, 이 문자들은 제어 문자(Cc)로 이미 거절하므로 value != value.strip() 검사를 그대로 써도 됩니다.
- 제어 문자·줄·문단 구분자는 unicodedata.category가 Cc, Zl, Zp인 문자입니다.
- 양방향 제어 문자(Bidi_Control)는 U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069입니다. 이모지 조합에 쓰이는 ZWJ(U+200D) 등 다른 서식 문자(Cf)는 허용합니다.
- 필드 검사는 기존 로그인 구현(auth_views.credentials)과 같은 순서로, required → 문자열 여부(invalid) → blank → max_length → UTF-8 인코딩 가능 여부(invalid) → min_length → invalid_format → invalid_choice입니다. 인코딩 검사는 value.encode("utf-8")의 UnicodeError로 판정합니다.
- learning_goal의 허용 목록은 sori/views.py의 GOALS와 같은 집합을 사용합니다.

### 클라이언트 IP 판정

로그인과 회원가입의 IP별 시도 제한은 아래 규칙으로 정한 집계 키를 사용합니다. 판정은 함수 하나에 모으며, v0.7.0 로그인의 REMOTE_ADDR 직접 사용(auth_views.count_ip)도 이 함수로 바꿉니다.

- 기본값은 REMOTE_ADDR입니다. REMOTE_ADDR이 TRUSTED_PROXIES에 속할 때만 CLIENT_IP_HEADER가 가리키는 헤더를 사용합니다. 앞뒤 공백을 제외한 값이 IP 주소 하나로 해석될 때만 사용하며, 헤더가 없거나 해석할 수 없으면 REMOTE_ADDR을 사용하고 경고 로그를 남깁니다.
- CLIENT_IP_HEADER에는 값이 IP 하나인 헤더만 지정합니다. X-Forwarded-For처럼 여러 주소를 담는 헤더는 해석 규칙이 환경마다 다르므로 이번 범위에서 지원하지 않습니다. 직접 연결한 요청의 전달 헤더는 어떤 것도 읽지 않습니다.
- 현재 배포의 CF-Connecting-IP는 Cloudflare가 방문자 IP로 설정하는 헤더입니다. 다만 Cloudflare 문서에 클라이언트가 보낸 값을 덮어쓴다는 내용이 명시되어 있지 않으므로, 위조할 수 없다는 점은 [배포 테스트](#배포-테스트) 4번으로 확인합니다. 이 테스트가 실패하면 터널을 닫고 판정 방식을 다시 정합니다.
- 집계 키는 IPv4는 주소 단위, IPv6는 /64 네트워크 단위입니다. IPv4-mapped IPv6 주소(::ffff:a.b.c.d)는 IPv4로 처리합니다.
- throttle_key는 SHA-256 대신 DJANGO_SECRET_KEY를 키로 하는 HMAC-SHA256(종류 + "\0" + 값)으로 바꿉니다. 아이디 키에도 같이 적용합니다. 솔트 없는 해시는 IPv4 주소 공간과 짧은 아이디를 전수 대입해 되돌릴 수 있기 때문입니다. SECRET_KEY를 바꾸면 기존 제한 상태가 초기화되는 것을 수용합니다.
- 로그인·가입 요청 로그에는 IP 집계 키의 throttle_key 앞 8자리만 남기고 IP 원문은 남기지 않습니다. [배포 테스트](#배포-테스트)에서 네트워크별로 값이 다른지 비교하는 용도입니다.
- LoginThrottle에 updated_at(auto_now)을 추가합니다. 워커 루프가 1시간마다 updated_at이 24시간보다 오래됐고 blocked_until이 없거나 지난 행을 삭제합니다. 가장 긴 집계 구간이 24시간이므로 제한 판정은 바뀌지 않습니다. locked_throttle은 행을 만들거나 가져온 뒤 잠금 조회 전에 이 정리로 행이 사라지면 다시 생성해 재시도합니다.

### 요청 미들웨어와 민감 정보

- RequestMiddleware의 32 KiB 본문 제한은 /api/v1/auth/login/과 /api/v1/auth/signup/의 POST에 적용하며, 413 메시지는 "요청 본문은 32 KiB 이하여야 합니다."입니다. 계정 삭제는 본문을 읽지 않으므로 대상이 아닙니다.
- 가입 뷰는 sensitive_post_parameters("password")로 password를 민감 파라미터로 지정합니다.
- 가입과 가입 가능 여부 뷰는 로그인과 같이 authentication_classes=[]와 AllowAny를 사용해 Authorization 헤더를 검사하지 않습니다.
- sori.errors.exception_handler는 DatabaseError(IntegrityError 포함), ObjectDoesNotExist 또는 OSError가 발생했을 때 요청 사용자가 DB에 더 이상 없으면 401 AUTHENTICATION_REQUIRED와 WWW-Authenticate: Bearer로 변환합니다. 계정 삭제와 겹친 요청이 삭제된 사용자를 참조하는 행을 쓰거나, 함께 삭제된 행을 저장·조회하거나 삭제된 파일을 읽다 실패하는 경우입니다. 사용자가 남아 있으면 기존처럼 처리합니다.

### 계정 삭제 절차

계정 삭제 API와 관리 명령 delete_practice_user는 같은 삭제 함수(sori.accounts.delete_account)를 사용합니다. 하나의 DB 트랜잭션에서 아래 순서로 잠그고 삭제하며, 일부만 삭제된 상태를 남기지 않습니다.

잠금 순서는 해당 아이디의 로그인 제한 행, 사용자의 응시 행(id 순), 사용자 행, 그 사이에 커밋된 응시 행을 다시 조회해 잠금입니다. 로그인은 제한 행을 잠근 채 사용자 행을 잠그므로 삭제도 제한 행을 먼저 잠급니다. 제출·업로드는 응시 행을 잠근 채 커밋 시점의 FK 확인에서 사용자 행을 참조하므로, 사용자 행을 먼저 잠그면 교착 상태가 생길 수 있습니다.

1. 사용자의 모든 응시에서 current_job과 submitted_answer 참조를 해제합니다. 이 참조와 GradingJob.answer가 PROTECT이므로, 해제하지 않으면 Django의 연쇄 삭제가 실패합니다.
2. 사용자의 GradingJob, SelfAssessmentRevision, Answer, Attempt를 삭제합니다. SelfAssessmentRevision.attempt도 PROTECT입니다. 삭제할 Answer의 이미지 경로는 이 단계에서 모아 둡니다.
3. 사용자의 IdempotencyRecord, Token, UserProfile, 해당 아이디의 로그인 실패 집계를 삭제합니다.
4. 사용자를 삭제합니다. AI 채점 사용량 기록은 사용자 연결만 끊고 보존합니다. 이 기록은 사용량 상한을 구현할 때 추가합니다.

- 커밋 후(transaction.on_commit) 모아 둔 답안 이미지 파일을 저장소에서 삭제합니다. 파일 삭제가 실패하면 요청 ID와 파일 경로를 서버 로그에 남겨 관리자가 정리합니다. 저장소 API에 디렉터리 삭제가 없으므로 빈 디렉터리는 남을 수 있습니다.
- 워커는 결과를 GradingJob.objects.filter(id=..., status="processing", attempt__current_job_id=...).update(...)로 저장하므로, 삭제된 작업의 결과는 갱신 행이 없어 버려집니다. 결과 저장에 save()를 쓰면 삭제된 행을 다시 INSERT할 수 있으므로 이 방식을 유지합니다.
- 다만 execute_job 안의 job.answer·job.attempt 조회와 워커 루프의 job.refresh_from_db()는 삭제된 행에서 DoesNotExist를 던집니다. 이 예외는 execute_job의 except 목록에 없어 워커 프로세스가 종료됩니다. 워커 루프는 execute_job부터 refresh_from_db까지를 ObjectDoesNotExist로 감싸고, 삭제된 작업이면 작업 ID만 로그에 남긴 뒤 다음 작업으로 넘어갑니다.
- delete_practice_user <username>은 비밀번호를 묻지 않는 대신 아이디를 다시 입력받아 확인하며, 관리자 계정과 사용 가능한 비밀번호가 없는 계정도 삭제할 수 있습니다.
- Django admin의 사용자 삭제는 PROTECT 참조 때문에 응시가 있는 사용자에서 실패하므로 계정 삭제 경로로 사용하지 않습니다.

### AI 채점 사용량 기록

- 사용자와 생성 시각을 담은 사용량 기록 모델을 추가합니다. 사용자 참조는 계정 삭제 시 null로 바꿉니다(SET_NULL). 생성 시각에 인덱스를 둡니다.
- 새 채점 작업을 만드는 트랜잭션에서 고정 키의 pg_advisory_xact_lock("sori:ai-quota"에서 만든 64비트 키)을 잡은 뒤, 최근 24시간의 기록을 사용자별·전체로 세고, 상한 이내이면 사용량 기록과 작업을 생성합니다. 전역 잠금이므로 동시 요청도 상한을 넘지 않습니다.
- 집계 쿼리에 SELECT … FOR UPDATE를 쓰지 않습니다. PostgreSQL은 집계 쿼리의 행 잠금을 허용하지 않고, 기존 행을 잠가도 새로 삽입되는 행을 막지 못하기 때문입니다.
- 잠금 순서는 run_idempotent의 advisory 잠금, 응시 행 잠금, 사용량 잠금입니다. 사용량 잠금을 항상 마지막에 잡아 교착을 피합니다. 모든 제출이 이 잠금에서 직렬화되지만 이 규모에서는 문제가 없습니다.
- 24시간이 지난 기록은 삭제할 수 있습니다.
- 429 GRADING_QUOTA_EXCEEDED 응답은 멱등성 영수증에 저장하지 않습니다.

## 앱 구현 노트

- 가입 화면의 username 입력란은 로그인 화면(LoginView.swift)과 같이 .textContentType(.username), .textInputAutocapitalization(.never), .autocorrectionDisabled()를 사용합니다.
- 비밀번호와 비밀번호 확인 입력란은 .textContentType(.newPassword)를 사용합니다. iOS의 강력한 비밀번호 제안과 자동 저장은 Associated Domains(webcredentials) 설정과 고정 도메인의 apple-app-site-association 파일이 있어야 확실히 동작합니다. Xcode 무료 개인 팀 서명과 주소가 바뀌는 Quick Tunnel에서는 사용할 수 없으므로 복구 불가 안내가 주된 대책입니다.
- username은 Regex의 wholeMatch처럼 문자열 전체 일치로 확인합니다.
- display_name 길이는 String.count(문자소 단위)가 아닌 unicodeScalars.count로 확인합니다. 문자 규칙은 Unicode.Scalar.Properties의 isWhitespace(앞뒤), generalCategory(.control, .lineSeparator, .paragraphSeparator), isBidiControl로 확인합니다.
- 서버 주소에는 터널의 https://<호스트>/api/v1/을 입력합니다. Quick Tunnel 주소가 바뀌면 기존 서버 변경 흐름(인증 작업 세대 갱신, origin별 토큰 분리)을 그대로 사용합니다.
- 프록시가 반환하는 HTML 오류는 ErrorEnvelope로 해석되지 않습니다. 현재 ExamAPI.execute는 이 경우 envelope=nil인 SORIError.server로 처리하고 401일 때만 인증 상태를 바꾸므로 그대로 유지합니다. error.code로 분기하는 화면(계정 삭제의 403 등)은 envelope=nil을 관리자 계정 안내 같은 계약 오류로 처리하지 않습니다. 해석할 수 없는 429는 Retry-After가 있으면 그 시간을 지킵니다.
- Debug 빌드는 모든 HTTP를 허용하므로 Release의 ATS 설정을 확인하지 못합니다. 배포 테스트 중 한 번은 Xcode 스킴의 Run 구성을 Release로 바꿔 설치합니다.

## 검증 항목

### v0.7.0 로그인 검증 항목 (구현 완료)

- OpenAPI에 Auth 태그, 두 POST 경로, 로그인 요청·응답 스키마와 오류 예시를 추가합니다. 공개 로그인에는 전역 인증을 해제하는 security: []를 지정하고, 로그아웃·/me/는 기존 BearerAuth를 유지합니다. 반영 후 계약 버전을 v0.7.0으로 맞춥니다.
- 기존 개발 계정 생성 명령은 set_unusable_password()를 사용하므로 그대로는 비밀번호 로그인이 불가능합니다. 관리자가 사용 가능한 비밀번호를 설정해야 합니다. 로그인 기능을 활성화하는 환경에서는 시작 시 개발 토큰을 자동 발급하는 동작을 중단해 로그아웃 후 서버 재시작으로 토큰이 다시 생성되지 않도록 합니다.
- 성공·실패 응답, 잘못된 Authorization 헤더가 있는 로그인, 입력 검증, 시도 제한·해제와 Retry-After, 동일 사용자 재로그인·동시 로그인, 프로필 UUID 유지, 로그아웃 후 기존 토큰 거부를 검증합니다. 비밀번호 변경·계정 비활성화의 토큰 회수와 재로그인·로그아웃 경합도 검증합니다.
- 로그인 본문 32 KiB 경계와 Content-Length 없는 초과 요청의 413, 아이디 제한 429의 IP 집계, IP 제한과 입력 오류가 겹칠 때의 429, 두 제한이 겹칠 때 더 긴 Retry-After를 검증합니다. 비밀번호 변경·재설정 및 비활성화와 로그인 경합에서도 이전 자격 증명으로 유효 토큰이 남지 않는지 검증합니다.
- 앱에서는 재실행 후 인증 복구, 401과 네트워크 실패의 구분, 늦은 401 처리, 계정 전환 시 로컬 기록 분리, 미제출 답안 보존과 동일 사용자 재로그인 후 제출 복구를 검증합니다.
- 앱에서 이전 세대의 로그인 성공·로그아웃 204·/me/ 응답을 무시하는지, 본문과 Content-Type 없는 로그아웃 204를 수용하는지, 로그인 오류 후 자동 재전송하지 않는지도 검증합니다.

### v0.8.0 검증 항목

- OpenAPI에서 POST /auth/signup/, GET /auth/signup-availability/, DELETE /me/, SignupRequest·SignupAvailability 스키마, 로그인 응답 스키마를 재사용한 201 응답과 오류 예시를 구현과 맞춥니다. AI 채점 사용량 상한을 구현한 뒤 GRADING_QUOTA_EXCEEDED의 x-status: planned를 제거하고 info.version을 0.8.0으로 맞춥니다.
- [운영 설정과 한도](#운영-설정과-한도)의 모든 설정을 settings.py에서 읽고 검증하며, backend/.env.example에 추가합니다.
- 성공 응답과 생성된 사용자·프로필·토큰, 요청한 learning_goal과 created_via=signup 저장, 절대 URL인 Location(.../api/v1/me/), 가입 직후 토큰으로 /me/ 조회, 같은 자격 증명으로 로그인 시 같은 토큰 반환을 검증합니다.
- 필드별 code 우선순위, password의 다중 FieldError, 알 수 없는 필드·객체가 아닌 본문의 fields=[], 짝이 맞지 않는 서로게이트의 invalid와 1024자 초과 시 max_length 우선, "student01\n"·"student01 "의 invalid_format, display_name의 양방향 제어 문자 거절과 ZWJ 허용, learning_goal의 invalid_choice, 비밀번호 정책을 검증합니다. 로그인의 password도 같은 우선순위인지 검증합니다.
- 대소문자만 다른 아이디의 409(가입과 관리자 생성 경로 모두), 동시 가입 시 하나만 성공, 실패 시 사용자·프로필·토큰이 남지 않는지 검증합니다.
- SIGNUP_ENABLED=false의 403, 32 KiB 경계와 Content-Length 없는 초과 요청의 413, 두 IP 제한과 해제, 같은 IP의 동시 가입이 성공 한도를 넘지 않는지, IP 제한 중 입력 오류의 429, 두 제한이 겹칠 때 더 긴 Retry-After, 로그인 시도 제한과의 분리, 가입 성공 시 아이디별 로그인 실패 초기화를 검증합니다.
- LOGIN_MAX_REQUESTS_PER_IP를 바꿨을 때 로그인 IP 제한이 그 값을 따르는지, 기본값 30에서 기존 동작과 같은지 검증합니다.
- 클라이언트 IP 판정은 Django 테스트 클라이언트로 REMOTE_ADDR와 헤더를 지정해 검증합니다. TRUSTED_PROXIES에 속한 REMOTE_ADDR의 CLIENT_IP_HEADER 사용, 신뢰하지 않는 REMOTE_ADDR의 CLIENT_IP_HEADER·X-Forwarded-For 무시, 신뢰 프록시인데 헤더가 없거나 잘못된 값일 때의 REMOTE_ADDR 사용, 두 설정 중 하나만 있을 때의 시작 실패, IPv6 /64 집계와 IPv4-mapped 주소 처리, 로그인에도 같은 판정이 적용되는지, 집계 키가 HMAC인지, 로그에 IP 원문 없이 키 앞 8자리만 남는지, 오래된 LoginThrottle 행 정리와 정리 후 locked_throttle의 재생성을 검증합니다. Docker Desktop에서는 LAN 기기가 같은 주소로 보일 수 있으므로 실기기 검증은 [배포 테스트](#배포-테스트)에서 터널로 합니다.
- gunicorn에서 로그인 본문 32 KiB 경계와 Content-Length 없는 초과 요청의 413이 유지되는지, PORT 설정을 따르는지 검증합니다.
- 프록시 경유 요청은 테스트 클라이언트로 검증합니다. TRUSTED_PROXIES의 REMOTE_ADDR에서 /admin/ 요청은 404, /api/·/assets/ 요청은 정상인지, 같은 /admin/ 요청이 다른 REMOTE_ADDR에서는 정상인지, X-Forwarded-Proto: https가 있으면 응답의 절대 URL과 Location이 https인지 검증합니다.
- 채점 상한은 사용자별·전체 상한과 해제, 동시 제출이 상한을 넘지 않는지, 429 이후 같은 Idempotency-Key 재요청의 성공, 새 작업을 만들지 않는 재제출의 비제한, SIGNUP_ENABLED=true에서 상한 미설정 시 시작 실패를 검증합니다. 계정 삭제 후에도 삭제된 사용자의 사용량이 전체 상한 집계에 남는지 검증합니다.
- 운영 설정은 잘못된 정수·1 미만 값·해석할 수 없는 TRUSTED_PROXIES의 시작 실패, SIGNUP_ENABLED 해석, 한도를 낮춘 뒤 집계 수가 한도를 넘을 때 공통 대기 시간 규칙에 따른 retry_after_ms를 검증합니다.
- 대소문자 무시 비교는 사전 확인·마이그레이션 조회가 lower(username)을 사용하는지, admin 사용자 변경 폼에서 대소문자만 다른 아이디로 바꿀 때 500이 아닌 폼 오류인지 검증합니다.
- create_practice_user가 created_via=signup 계정의 비밀번호를 바꾸지 않는지, 기존 프로필이 마이그레이션으로 admin이 되는지 검증합니다.
- GET /auth/signup-availability/는 설정값 반영, 잘못된 Authorization 헤더와 무관한 200, 시도 제한 미포함을 검증합니다.
- 계정 삭제는 204 후 사용자·프로필·토큰·응시·답안·채점 작업·자기채점 이력·멱등성 영수증·로그인 실패 기록·이미지 파일이 남지 않는지, 이전 토큰의 401, 같은 아이디 재가입 시 새 UUID, 관리자 계정의 403과 데이터 유지, 본문·Content-Type과 무관한 204, 다른 사용자의 데이터 유지, 실패 시 일부만 삭제되지 않는지, 이미지 파일 삭제 실패에도 204인지를 검증합니다. 진행 중인 채점 작업이 있을 때 삭제하면 워커가 종료되지 않고 결과만 버려지는지, 삭제와 겹친 응시 생성 요청이 500이 아닌 401을 받는지, 삭제와 겹친 제출·업로드가 교착 상태 없이 끝나는지도 검증합니다. delete_practice_user도 같은 결과를 내는지 검증합니다.
- 남용 대응 절차대로 계정을 비활성화하면 토큰이 폐기되고 로그인·제출이 거절되는지 검증합니다.
- 앱에서는 가입 성공 후 인증 상태와 로컬 기록 연결, 이전 세대 가입 응답 무시, 오류 후 자동 재전송하지 않음, 응답 유실 후 409·429 안내, signup-availability 결과에 따른 가입 버튼 표시, 403 후 버튼 숨김, 학습 목표 선택 필수, 개인정보·복구 불가 안내 표시, GRADING_QUOTA_EXCEEDED 안내와 자동 재전송하지 않음, 대기 시간이 30초를 넘는 429의 자동 재시도 제외, 80자 display_name 표시를 검증합니다.
- 앱의 계정 삭제는 204 후 토큰·로컬 기록 삭제와 로그인 화면 이동, 진행 중이던 필기가 삭제 후 다시 저장되지 않음, 403 ACCOUNT_DELETION_NOT_ALLOWED 후 토큰 유지, 이전 세대 삭제 응답 무시, 오류 후 자동 재전송하지 않음, 응답 유실 후 401의 안내와 로컬 기록 유지, 본문을 해석할 수 없는 403을 관리자 계정 오류로 처리하지 않음을 검증합니다.

### 배포 테스트

[배포 점검 항목](#배포-점검-항목)을 마친 뒤 터널을 열고 테스트 기기 두 대로 수행합니다.

| # | 시나리오 | 기대 결과 |
|---|---|---|
| 0 | scripts/start-windows.ps1로 서버만 시작 | db, api, worker가 실행되고 cloudflared는 실행되지 않음 |
| 1 | 두 기기 모두 https://<터널 호스트>/api/v1/로 로그인하고 문제를 열어 답안을 업로드하고 제출 | 문제 상세의 자산 url이 https://<터널 호스트>/…이고 업로드가 성공하며 채점까지 완료 |
| 2 | 한 기기는 Wi-Fi, 다른 기기는 휴대폰 핫스팟에서 로그인 | 서버 로그의 IP 키 앞 8자리가 서로 다름. 같다면 TRUSTED_PROXIES 설정 오류 |
| 3 | 두 기기를 같은 Wi-Fi에서 로그인 | IP 키가 같음(같은 공인 IP를 공유하는 경우) |
| 4 | 터널 주소로 `curl -H "X-Forwarded-For: 203.0.113.1" -H "CF-Connecting-IP: 203.0.113.1" …/api/v1/auth/login/` | IP 키가 위조 값이 아닌 요청한 컴퓨터의 실제 IP 기준으로 유지됨. 실패하면 터널을 닫고 판정 방식을 다시 정함 |
| 5 | 같은 아이디로 틀린 비밀번호 로그인 5회 | 429와 Retry-After, retry_after_ms가 Cloudflare를 거쳐도 유지됨 |
| 6 | 터널 주소의 /admin/ 접속 | 404. localhost의 /admin/은 정상 |
| 7 | 터널을 연 채 `docker compose --env-file backend/.env stop api` 후 앱 사용 | Cloudflare의 HTML 5xx를 받아도 로그아웃되지 않고 연결 실패로 안내 |
| 8 | 터널 재시작(Quick Tunnel은 주소가 바뀜) 후 새 주소 입력 | 서버 변경 흐름으로 재로그인하며 이전 origin의 토큰을 새 서버로 보내지 않음 |
| 9 | 채점이 진행 중일 때 계정 삭제 | 204. 워커가 계속 실행되고 결과는 저장되지 않음 |
| 10 | Release 구성으로 설치한 앱에서 1번 반복 | ATS 오류 없이 동작 |
| 11 | 테스트 종료 후 `docker compose --env-file backend/.env --profile tunnel stop cloudflared` | 터널 주소 접속 불가, SIGNUP_ENABLED=false로 복귀 |
