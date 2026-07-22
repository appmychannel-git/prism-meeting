# Mac / iOS 빌드 인수인계 (Claude 읽는 문서)

> 이 문서는 **Mac에서 Claude Code로 iOS 빌드를 이어서 진행**하기 위한 컨텍스트입니다.
> Windows에서 안드로이드·웹은 이미 완성됐고, **iOS만 추가하면 됩니다.**

---

## 1. 프로젝트 개요

**Prism Meeting** — Flutter 기반 소규모 다자간 화상회의 앱.
- 미디어: **LiveKit(SFU)** — `livekit_client` ^2.8
- 타깃: 안드로이드(폰/TV/태블릿) · 웹 · **iOS(이번에 추가)**
- 코드는 `lib/`에 공통 → iOS도 그대로 재사용, **UI/기능 재작성 불필요**

## 2. 현재 상태

| 플랫폼 | 상태 |
|--------|------|
| 안드로이드 | ✅ 완성 (APK 배포/설치 검증) |
| 웹 | ✅ 완성 (`https://androidtv.mychannel.co.kr/meeting/` 에 정적 배포) |
| **iOS** | ❌ **미설정** — 이 문서대로 진행 |

이 저장소는 `flutter create --platforms=android,web` 로 생성돼 **`ios/` 폴더가 없습니다.** 아래에서 추가합니다.

## 3. 핵심 설정값 (그대로 사용)

- **토큰 서버(고정)**: `https://prism-token-server.onrender.com/token`
  - 빌드/실행 시 반드시 주입: `--dart-define=LK_TOKEN_URL=https://prism-token-server.onrender.com/token`
- **LiveKit Cloud** 프로젝트: `wss://mychannel-meeting-prism-h0684ccm.livekit.cloud` (토큰서버가 처리, 앱은 몰라도 됨)
- **앱 표시 이름**: `Prism Meeting`
- **안드로이드 applicationId**: `com.prism.prism_meeting` → iOS bundle id 는 언더스코어 불가라 예: `com.prism.prismMeeting` 권장

## 4. 프로젝트 구조 (공통 코드)

```
lib/
  main.dart              # 앱 진입
  config.dart            # LK_TOKEN_URL, 방정원, TV상한, 기기 identity
  connection_service.dart# 토큰서버 호출 (identity/name 분리)
  join_screen.dart       # 입장 화면 (TV D-pad 대응)
  room_screen.dart       # 회의 화면 (갤러리/발표자뷰/채팅/재연결배너/wakelock 등)
  chat_panel.dart        # 채팅 패널
```

## 5. iOS 빌드 작업 (단계별) ★

### 5-1. iOS 플랫폼 추가
```bash
cd prism-meeting
flutter pub get
flutter create --platforms=ios .   # ios/ 폴더 생성 (기존 코드 안 건드림)
```

### 5-2. Info.plist 권한 추가 (필수 — 없으면 카메라 접근 시 크래시)
`ios/Runner/Info.plist` 에 추가:
```xml
<key>NSCameraUsageDescription</key>
<string>화상회의 영상 통화를 위해 카메라를 사용합니다.</string>
<key>NSMicrophoneUsageDescription</key>
<string>화상회의 음성 통화를 위해 마이크를 사용합니다.</string>
```
(선택) 백그라운드에서도 통화 유지하려면:
```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <string>voip</string>
</array>
```

### 5-3. iOS 배포 타깃 (livekit/flutter_webrtc 요구)
`ios/Podfile` 상단:
```ruby
platform :ios, '13.0'
```

### 5-4. 앱 아이콘 (기존 소스 재사용)
`assets/icon/app_icon.png` 가 이미 있음. `pubspec.yaml` 의 `flutter_launcher_icons:` 에 iOS 추가:
```yaml
flutter_launcher_icons:
  android: true
  ios: true          # ← 이 줄 추가
  image_path: "assets/icon/app_icon.png"
  ...
```
그 후:
```bash
dart run flutter_launcher_icons
```

### 5-5. 서명(Signing) — Xcode
```bash
open ios/Runner.xcworkspace
```
- Runner 타깃 → Signing & Capabilities → **Team**(Apple Developer 계정) 선택
- **Bundle Identifier** 설정 (예: `com.prism.prismMeeting`)
- 실기기 테스트/배포엔 **Apple Developer 계정($99/년)** 필요

### 5-6. 빌드/실행
```bash
# 실기기/시뮬레이터 실행 (카메라는 실기기에서만)
flutter run -d <ios-device-id> --dart-define=LK_TOKEN_URL=https://prism-token-server.onrender.com/token

# 배포용 IPA
flutter build ipa --dart-define=LK_TOKEN_URL=https://prism-token-server.onrender.com/token
```

## 6. 플랫폼별 주의사항 (Android ↔ iOS 차이)

| 항목 | Android(적용됨) | iOS |
|------|----------------|-----|
| 권한 | AndroidManifest | **Info.plist (5-2 필수)** |
| Impeller 렌더러 | **끔**(저가 박스 대응, manifest) | **iOS는 끄지 말 것** — Metal 기반이라 잘 됨(기본값 유지) |
| 영상 코덱 H.264 | `RoomOptions(videoCodec:'h264')` — 코드 공통 | 그대로 OK (iOS H264 HW 지원 우수) |
| wakelock | `wakelock_plus` | iOS 지원됨, 그대로 동작 |
| identity/name 분리 | 코드 공통 | 그대로 동작 |

> 핵심: **`lib/` 코드는 손댈 필요 없음.** iOS 전용은 `ios/Runner/Info.plist` 권한 + Xcode 서명 + Podfile 타깃뿐.

## 7. 검증 방법

- iOS 기기 + 안드로이드/웹에서 **같은 방 이름**으로 입장 → 서로 보이면 성공 (같은 LiveKit 프로젝트)
- 카메라/마이크 권한 팝업이 뜨고 허용되는지 확인 (Info.plist 문구가 보임)

## 8. Git 동기화 워크플로우

```
GitHub: appmychannel-git/prism-meeting  (단일 원본)
  Windows(안드로이드/웹)  ↔  Mac(iOS)
```
- 수정 후: `git add -A && git commit -m "..." && git push`
- 반대편: `git pull`
- **양쪽을 각각 고치지 말 것.** 한 번 고치고 push/pull 로 동기화.
- iOS 설정 완료되면 `ios/` 폴더도 commit → Windows에도 들어옴(안드로이드 빌드엔 무해).

---

## 참고 — 안드로이드 빌드/배포 명령 (Windows 쪽, 참고용)
```powershell
flutter build apk --release --dart-define=LK_TOKEN_URL=https://prism-token-server.onrender.com/token
```
웹:
```powershell
flutter build web --base-href /meeting/ --dart-define=LK_TOKEN_URL=https://prism-token-server.onrender.com/token
```
