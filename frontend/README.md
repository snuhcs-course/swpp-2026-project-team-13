# SwiftUI iPad 앱

Mac의 Xcode 16 이상에서 `IPadApp/IPadApp.xcodeproj`를 엽니다.
`IPadApp` scheme, iPad 시뮬레이터를 선택하고 Run을 누릅니다. 대상은 iPadOS 17 이상입니다.
첫 화면과 Django 서버 연결 확인 버튼만 구현되어 있습니다.

## 서버 주소

- Debug: `IPadApp/Config/Debug.xcconfig`의 `http://localhost:8000`
- 개인 Debug 설정: `Local.xcconfig.example`을 같은 폴더의 `Local.xcconfig`로 복사 후 수정
- Release: `Release.xcconfig`에 실제 HTTPS API 주소 설정 필요. 현재 비어 있으며 요청 시 안내 메시지를 표시

xcconfig에서는 `//`가 주석이므로 URL을 `http:/$()/localhost:8000`처럼 씁니다.
빌드된 앱에서는 `http://localhost:8000`으로 치환됩니다.

실제 iPad에서 테스트하려면:

1. iPad와 Mac을 같은 네트워크에 연결합니다.
2. 개인 `Config/Local.xcconfig`의 주소를 Mac의 LAN IP로 바꿉니다.
3. 백엔드의 `DJANGO_ALLOWED_HOSTS`에 같은 IP를 추가하고 `runserver 0.0.0.0:8000`으로 실행합니다.
4. Xcode의 Signing & Capabilities에서 본인의 Team을 선택하고 필요하면 bundle identifier를 고유하게 바꿉니다.
5. 앱을 다시 빌드해 실행합니다. 로컬 네트워크 접근을 허용하고 Mac 방화벽에서 개발 서버 연결을 허용합니다.

시뮬레이터는 개발자 Team이나 개인 서명 설정 없이 실행할 수 있습니다.
로컬 HTTP를 위해 `NSAllowsLocalNetworking`을 설정했습니다. 배포 서버는 HTTPS를 사용합니다.

## 파일 역할

| 파일 | 역할 |
| --- | --- |
| `IPadAppApp.swift` | 앱 진입점 |
| `ContentView.swift` | 시작 화면과 비동기 연결 상태 |
| `APIClient.swift` | URLSession 요청, HTTP 오류 처리, JSON 디코딩 |
| `Info.plist` | API 주소 주입과 로컬 네트워크 사용 안내 |
| `Assets.xcassets` | 강조 색과 앱 아이콘 자리 |

`IPadApp`과 `org.snuhcs.team13.ipadapp`은 초기 이름입니다.
앱 이름·아이콘·배포 서명·운영 API 주소는 추후 설정합니다.
필기 입력, 필기 인식, 로그인, 로컬 저장은 아직 없습니다.
