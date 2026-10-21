# 맥북 작업 가이드 — iOS 소셜 로그인(카카오·구글) + [등록하기] 링크

작성 2026-10-21. 안드로이드는 완료·실기 검증됨(커밋 9e0ab88, 403e56b, 7380ddf).
iOS 는 같은 Dart 코드를 쓰지만 **네이티브 쪽이 비어 있어** 아래 3가지가 동작하지 않는다.
작업 후 점검은 [ios-login-access-checklist.md](ios-login-access-checklist.md) 로 한다.

| # | 기능 | iOS 현재 | 이 문서 섹션 |
|---|---|---|---|
| 1 | 카카오 로그인 | 채널 `app/kakao` 없음 → 오류 안내만 | §2 |
| 2 | 구글 로그인 | Info.plist 설정 없음 → 시작 안 됨/종료 가능 | §3 |
| 3 | [등록하기]·업데이트 열기 | 채널 `app/fullscreen` 없음 → 눌러도 무반응 | §4 |

> 이메일 로그인, 정책 API(app-policy.asp), 기기 인증 배너, 메뉴 로그아웃, 영어 처리는 Dart 공통이라 iOS 작업 불필요.

---

## 0. 시작 전

```bash
git pull                       # 윈도우에서 커밋한 것(9e0ab88 이후) 받기 — 윈도우 쪽 push 먼저 필요
flutter pub get
cd ios && pod install && cd ..
```

- 번들 ID: `kr.co.mychannel.meeting.prism` (iOS 는 브랜드 flavor 없음, 이것 하나)
- AppDelegate 는 **implicit engine** 방식(`FlutterImplicitEngineDelegate`) + `SceneDelegate`(FlutterSceneDelegate). 채널은 `didInitializeImplicitFlutterEngine` 안에서 만든다.
- **건드리지 말 것**: 애플 로그인 엔타이틀먼트(커밋 dc41160 에서 일시 제거 — Capability 활성화 후 별도 복원), VoIP/CallKit 코드.

---

## 1. 콘솔 등록(맥 작업 전에 해 두면 좋음)

### 카카오 (developers.kakao.com)
- 앱: **VIEWPLUS (ID 1573280)** — 지금 기본 키 `bd28f3b76080e0b4d64865386a35319d`("viewplus mychannel") 가 있는 앱.
  (prism 번들로 다른 키를 쓰려면 그 키의 플랫폼에 등록)
- 플랫폼 키 > 그 네이티브 앱 키 > **iOS 번들 ID** 에 `kr.co.mychannel.meeting.prism` 추가
- 카카오 로그인 활성화 상태 확인

### 구글 (console.cloud.google.com, 프로젝트 **800914840538** — "viewplus")
- 사용자 인증 정보 > 만들기 > OAuth 클라이언트 ID > **iOS** > 번들 ID `kr.co.mychannel.meeting.prism`
- 생성된 **iOS 클라이언트 ID**(`800914840538-xxxx.apps.googleusercontent.com`)와
  **역순 클라이언트 ID**(`com.googleusercontent.apps.800914840538-xxxx`)를 메모
- 서버용 웹 클라이언트 ID(이미 있음): `800914840538-k4ovs9na1rg7patpc2q85qk81dnagevv.apps.googleusercontent.com`
- ⚠ Firebase 프로젝트(mychannel-meeting-ed929)가 아니라 **800914840538** 이다(서버가 이 프로젝트의 웹 클라 ID 로 토큰 aud 를 검사).

---

## 2. 카카오 로그인 (iOS 네이티브 채널 `app/kakao`)

Dart 쪽 계약(바꾸지 말 것 — `lib/mobile_auth.dart` `loginKakao()`):
- `MethodChannel('app/kakao').invokeMethod<String>('login')`
- 성공 → **access_token 문자열** 반환
- 사용자 취소 → `FlutterError(code: "cancelled")`
- 그 외 실패 → `FlutterError(code: "kakao", message: ...)`

### 2-1. Podfile
`ios/Podfile` 의 `target 'Runner' do` 안에:
```ruby
pod 'KakaoSDKUser', '~> 2.20'   # KakaoSDKAuth/Common 포함
```
→ `cd ios && pod install`
> pub 의 kakao_flutter_sdk 는 쓰지 않는다(pointycastle 3.x 가 livekit 4.x 와 충돌 — 안드로이드도 같은 이유로 네이티브).

### 2-2. Info.plist
```xml
<!-- CFBundleURLTypes 배열에 항목 추가 (기존 prismmeeting 스킴은 유지) -->
<dict>
  <key>CFBundleURLSchemes</key>
  <array>
    <string>kakaobd28f3b76080e0b4d64865386a35319d</string>
  </array>
</dict>

<!-- 카카오톡 앱 호출 허용 -->
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>kakaokompassauth</string>
  <string>kakaolink</string>
</array>
```
(이미 `LSApplicationQueriesSchemes` 가 있으면 배열에 추가)

### 2-3. AppDelegate.swift
```swift
import KakaoSDKCommon
import KakaoSDKAuth
import KakaoSDKUser

// didFinishLaunchingWithOptions 안, super 호출 전:
KakaoSDK.initSDK(appKey: "bd28f3b76080e0b4d64865386a35319d")

// didInitializeImplicitFlutterEngine 안, GeneratedPluginRegistrant 뒤:
if let reg = engineBridge.pluginRegistry.registrar(forPlugin: "AppKakaoChannel") {
  let ch = FlutterMethodChannel(name: "app/kakao", binaryMessenger: reg.messenger())
  ch.setMethodCallHandler { call, result in
    guard call.method == "login" else { result(FlutterMethodNotImplemented); return }
    let done: (OAuthToken?, Error?) -> Void = { token, error in
      if let token = token { result(token.accessToken); return }
      if let e = error as? SdkError, case .ClientFailed(let reason, _) = e, reason == .Cancelled {
        result(FlutterError(code: "cancelled", message: "user cancelled", details: nil)); return
      }
      result(FlutterError(code: "kakao", message: error?.localizedDescription ?? "login failed", details: nil))
    }
    if UserApi.isKakaoTalkLoginAvailable() {
      UserApi.shared.loginWithKakaoTalk { token, error in
        // 톡 로그인 실패(취소 제외) → 카카오계정(웹)으로 폴백 — 안드로이드와 동일
        if token == nil, let e = error as? SdkError, case .ClientFailed(let r, _) = e, r == .Cancelled {
          done(nil, error)
        } else if token == nil {
          UserApi.shared.loginWithKakaoAccount(completion: done)
        } else {
          done(token, nil)
        }
      }
    } else {
      UserApi.shared.loginWithKakaoAccount(completion: done)
    }
  }
}
```

### 2-4. 카카오톡에서 돌아오는 URL 처리 — SceneDelegate.swift
```swift
import KakaoSDKAuth

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url, AuthApi.isKakaoTalkLoginUrl(url) {
      _ = AuthController.handleOpenUrl(url: url)
      return
    }
    super.scene(scene, openURLContexts: URLContexts)   // 딥링크(prismmeeting://) 등 기존 처리 유지
  }
}
```
> 브랜드별 카카오 키로 나눌 때(안드로이드는 flavor `kakaoKey`)는 키를 Info.plist 의 사용자 키(예: `KAKAO_APP_KEY`)로 빼고 AppDelegate 에서 `Bundle.main.object(forInfoDictionaryKey:)` 로 읽으면 된다. 지금은 번들이 하나라 하드코딩으로 충분.

---

## 3. 구글 로그인 (google_sign_in 플러그인 — 설정만)

`ios/Runner/Info.plist` 에 추가(§1 에서 받은 값):
```xml
<key>GIDClientID</key>
<string>800914840538-xxxx.apps.googleusercontent.com</string>          <!-- iOS 클라이언트 ID -->
<key>GIDServerClientID</key>
<string>800914840538-k4ovs9na1rg7patpc2q85qk81dnagevv.apps.googleusercontent.com</string>  <!-- 웹(서버) -->

<!-- CFBundleURLTypes 배열에 항목 추가 -->
<dict>
  <key>CFBundleURLSchemes</key>
  <array>
    <string>com.googleusercontent.apps.800914840538-xxxx</string>     <!-- 역순 iOS 클라이언트 ID -->
  </array>
</dict>
```
- Dart 는 이미 `GoogleSignIn(serverClientId: 웹 클라 ID)` 로 호출한다(`lib/mobile_auth.dart`) — 코드 수정 불필요.
- 서버는 id_token 의 aud 를 웹 클라 ID 로 검사하므로 serverClientId 가 맞아야 한다.

---

## 4. [등록하기]·업데이트 열기 (채널 `app/fullscreen`)

Dart 쪽(`lib/app_gate_block.dart` `openUpdate`)이 쓰는 메서드:
- `openUrl` `{url}` → 그 주소를 사파리로 (기기 인증 배너의 [등록하기] = `https://viewplus.co.kr/my/profile`, 강제/권장 업데이트의 update_url)
- `openStore` → 스토어의 이 앱 페이지

AppDelegate `didInitializeImplicitFlutterEngine` 안:
```swift
if let reg = engineBridge.pluginRegistry.registrar(forPlugin: "AppFullscreenChannel") {
  let ch = FlutterMethodChannel(name: "app/fullscreen", binaryMessenger: reg.messenger())
  ch.setMethodCallHandler { call, result in
    switch call.method {
    case "openUrl":
      if let s = (call.arguments as? [String: Any])?["url"] as? String, let u = URL(string: s) {
        UIApplication.shared.open(u)
      }
      result(true)
    case "openStore":
      // App Store 등록 후 실제 앱 ID 로 교체: itms-apps://apps.apple.com/app/id<APP_ID>
      result(false)
    default:
      result(FlutterMethodNotImplemented)   // 안드로이드 전용 메서드(전체화면 알림 설정 등)
    }
  }
}
```
> 이 채널의 다른 메서드는 안드로이드 전용이다. Dart 호출부가 모두 try/catch 라 notImplemented 로 둬도 안전.

---

## 5. 빌드·확인

```bash
flutter analyze
flutter build ios --release --dart-define=... # 기존 iOS 빌드 스크립트/옵션 그대로 (USE_STORE_LOGIN 등)
```
- 실기(아이폰)에서 [ios-login-access-checklist.md](ios-login-access-checklist.md) 2-1 ~ 2-6 진행
- 특히: #10 [등록하기] 사파리 열림, #21 구글, #22·#23 카카오(톡 설치/미설치), #26~#31 영어
- 안드로이드 회귀 없음 확인: `flutter build apk --release --flavor viewplus` 정도면 충분(Dart 변경이 없으면 생략 가능)

## 6. 끝나면

- 체크리스트 결과 칸 채워서 커밋
- `ios-login-access-checklist.md` §0 표의 P1~P3 상태를 "완료"로 갱신
- 애플 로그인 엔타이틀먼트 복원 여부는 별도 판단(Apple Developer 에서 Sign in with Apple Capability 활성화가 먼저)
