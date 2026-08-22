# iOS Firebase / 푸시 드롭인 체크리스트 (prism 브랜드)

앱 코드와 iOS 프로젝트는 **Firebase 드롭인 준비 완료** 상태다.
아래 계정 작업만 하면 iOS에서 **통화·친구·수신 푸시**가 동작한다.
(개발자가 대신 못 하는 계정 작업 — Firebase 콘솔 / Apple Developer)

계정: Firebase = `appmychannel@gmail.com`, Apple = 개발팀 `N7653V74T8`

---

## 1. Firebase 콘솔 — iOS 앱 등록 (prism)

1. https://console.firebase.google.com → 기존 프로젝트(Android가 등록된 그 프로젝트) 선택
2. **앱 추가 → iOS**
   - **Apple bundle ID**: `kr.co.mychannel.meeting.prism`  ← 정확히 일치해야 함
   - App nickname: `Prism Meeting iOS` (자유)
3. **`GoogleService-Info.plist` 다운로드**
4. 이 파일을 저장소의 **`ios/Runner/GoogleService-Info.plist`** 로 저장
   - ⚠️ Xcode에서 Runner 타깃에 포함되어야 함(파일 추가 시 "Add to targets: Runner" 체크).
     Claude에게 "plist 넣었어" 라고 하면 Xcode 타깃 포함까지 스크립트로 처리해 줌.

> 이 파일은 앱 식별 정보라 **git에 올려도 치명적이진 않으나**, 관례상 커밋하지 않는다면
> `.gitignore` 에 추가하고 Mac에만 두면 된다. (브랜드마다 다른 파일)

## 2. Apple Developer — APNs 인증 키 (푸시 필수)

1. https://developer.apple.com/account → **Certificates, Identifiers & Profiles → Keys**
2. **+ (새 키)** → 이름 입력 → **Apple Push Notifications service (APNs)** 체크 → 생성
3. **`.p8` 키 파일 다운로드**(한 번만 받을 수 있음) + **Key ID** 기록, **Team ID**(`N7653V74T8`) 확인

## 3. Firebase 콘솔 — APNs 키 업로드

1. Firebase 프로젝트 → **프로젝트 설정 → Cloud Messaging** 탭
2. **Apple 앱 구성 → APNs 인증 키 → 업로드**: 위 `.p8` + Key ID + Team ID 입력

## 4. Apple Developer — App ID 캡ability (자동 서명이 대부분 처리)

`kr.co.mychannel.meeting.prism` App ID에 아래가 켜져 있어야 함(Xcode 자동 서명이 보통 자동 등록):
- **Push Notifications**
- **App Groups** (`group.kr.co.mychannel.meeting.prism`, 화면공유용 — 이미 설정됨)
- **Associated Domains** (Universal Links — 이미 설정됨)

Xcode에서 Runner 타깃 → Signing & Capabilities 에서 **Push Notifications** 캡ability가 없으면
`+ Capability` 로 추가(자동 서명이 aps-environment 엔타이틀먼트 생성).

---

## 이미 코드/프로젝트에 준비된 것 (건드릴 필요 없음)

- `Info.plist`: `UIBackgroundModes`에 `remote-notification`·`voip`·`audio` 추가됨
- iOS 배포 타깃 15.0 (Firebase iOS SDK 최소 요구)
- `PushService.initIfEnabled()` — Firebase 구성 없으면 조용히 skip(앱은 정상 실행),
  plist 넣으면 그때부터 FCM 토큰 발급·수신 동작
- 권한 문구(Info.plist): 카메라·마이크·음성인식·사진

## 검증

1. `ios/Runner/GoogleService-Info.plist` 배치 + Xcode 타깃 포함
2. `flutter build ipa ...` → TestFlight 업로드
3. 실기기 2대(또는 안드로이드 1 + iOS 1)에서 친구 등록 → 통화 발신 → 수신 푸시/벨소리 확인
