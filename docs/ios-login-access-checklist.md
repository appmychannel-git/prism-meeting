# 아이폰 로그인·권한(기기 인증) 점검 체크리스트

작성 2026-10-21 · 안드로이드(갤럭시 S22+, viewplus 미팅 v1.0.30)에서 확인한 동작을 아이폰에서도 같은지 확인하기 위한 문서.

---

## 0. 먼저 알아둘 것 — 아이폰은 아직 준비가 덜 됐다

코드 확인 결과(2026-10-21) 아이폰 쪽은 아래가 **아직 없다**. 이 상태로 테스트하면 해당 항목은 실패가 정상이다.
체크리스트 전에 먼저 처리하거나, 실패 항목으로 기록만 할 것.

| # | 항목 | 현재 상태 | 해야 할 일 |
|---|---|---|---|
| P1 | **카카오 로그인** | 안드로이드는 네이티브 채널 `app/kakao`(MainActivity.kt)로 구현. **iOS 에는 이 채널이 없다** → 버튼을 누르면 오류 안내만 뜬다 | iOS 네이티브(KakaoSDK, `AppDelegate`)에 같은 채널 구현, 또는 Flutter 플러그인으로 교체. 카카오 콘솔에 **iOS 플랫폼(번들 ID)** 등록, Info.plist 에 `kakao{네이티브앱키}` URL 스킴 + `LSApplicationQueriesSchemes`(kakaokompassauth, kakaolink) |
| P2 | **구글 로그인** | Info.plist 에 `GIDClientID` 와 **iOS 클라이언트 ID 역순 URL 스킴**(`com.googleusercontent.apps.…`)이 없다 → google_sign_in 이 시작되지 않거나 앱이 종료될 수 있다 | GCP 프로젝트 **800914840538** 에 iOS OAuth 클라이언트(번들 ID) 생성 → Info.plist 에 `GIDClientID`, `GIDServerClientID`(웹 클라이언트 ID `800914840538-k4ov…`), 역순 URL 스킴 추가 |
| P3 | **[등록하기] 버튼**(웹 마이페이지 열기) | 안드로이드 채널 `app/fullscreen` → `openUrl` 사용. **iOS 에는 없다** → 눌러도 아무 일도 안 일어난다(오류는 숨김) | iOS 에 같은 채널 구현(`UIApplication.shared.open`), 또는 url_launcher 사용 |
| P4 | **번들 ID / 브랜드** | iOS 는 `kr.co.mychannel.meeting.prism` 하나뿐(안드로이드처럼 브랜드별 flavor 없음) | 테스트할 브랜드를 정하고, 카카오·구글 콘솔에 그 번들 ID 를 등록 |
| P5 | 애플 로그인 | 구현됨(sign_in_with_apple, App Store 가이드라인 4.8). 단 커밋 dc41160 에서 **applesignin 엔타이틀먼트를 일시 제거**(Capability 활성화 전 서명 깨짐 방지) → 그동안 애플 로그인은 실패할 수 있다 | Apple Developer 에서 Sign in with Apple Capability 활성화 후 엔타이틀먼트 복원. 버튼은 아이폰에서만 보이는지 확인(아래 2-4) |

> 이메일 로그인, 정책 API, 기기 인증 배너, 메뉴의 로그아웃은 **Dart 코드만** 쓰므로 아이폰에서도 그대로 동작해야 한다.

---

## 1. 테스트 준비

- **계정 2개**
  - A: 기기 인증 **완료** 계정(웹 마이페이지 > 프로필 > TV 시리얼 등록됨) — 예: 구글 계정
  - B: 기기 인증 **안 한** 계정(TV 시리얼 비어 있음) — 예: 카카오 계정
- **서버 정책**: 미팅 = `registered`(기기 인증 필요). 아래 주소로 미리 확인:
  ```
  https://platformtvapi.mychannel.co.kr/gbled/appinterface/tv/1.0/app-policy.asp?app=meeting&brand=viewplus&cuid=CH26345929&app_version_code=30&isMobile=Y&language=ko
  ```
  → `"access_policy":"registered"`, `"deny_message":"TV 시리얼 등록이 필요합니다. …"`
- 정책은 앱에 **최대 1시간 저장**된다(`cache_sec`). 서버 값을 바꾼 직후 확인하려면 앱을 지우고 다시 설치.
- 언어를 바꾸면 저장값을 무시하고 그 언어로 다시 받는다.

---

## 2. 체크리스트

결과 칸에 ✅ / ❌ / ➖(해당 없음) 와 메모.

### 2-1. 로그인 전

| # | 확인 | 기대 결과 | 결과 |
|---|---|---|---|
| 1 | 앱 첫 실행(로그아웃 상태) | 홈 상단 배너: 🔒 "로그인·기기 인증을 하면 방 만들기·친구·통화를 쓸 수 있어요." + **[로그인]** | |
| 2 | 홈 화면 기능 | **참여하기만** 보임. 방 만들기 탭·친구·통화 기록 없음. 회의 입장은 됨 | |
| 3 | 메뉴(☰) | **로그인** 항목이 있음(로그아웃 아님) | |
| 4 | 배너 [로그인] 또는 메뉴 [로그인] | 로그인 화면이 열림 | |

### 2-2. 기기 인증 **안 한** 계정(B)으로 로그인

| # | 확인 | 기대 결과 | 결과 |
|---|---|---|---|
| 5 | 로그인 직후 | 하단 안내 "로그인됐어요. 기기 인증(TV 시리얼 등록) 후 모든 기능을 쓸 수 있어요." 후 홈으로 | |
| 6 | 홈 배너 | 🛡 "TV 시리얼 등록이 필요합니다. 휴대폰에서 등록을 완료해 주세요." + 둘째 줄 "회의 참여는 지금도 할 수 있어요." + **[등록하기]**, 작은 **[다시 확인]** | |
| 7 | 회의 입장 | 방 코드로 **입장 가능**(막히지 않음) | |
| 8 | 방 만들기·친구·통화 | 보이지 않음 | |
| 9 | [다시 확인] | 잠깐 로딩 후 하단 "아직 기기 인증이 확인되지 않았어요." | |
| 10 | [등록하기] | 사파리로 `viewplus.co.kr/my/profile` 열림(미로그인 시 웹 로그인 화면 → 로그인 후 프로필) — **P3 처리 전이면 ❌ 정상** | |
| 11 | 웹에서 TV 시리얼 등록 → 앱으로 복귀 | 자동 재확인 → 배너 사라지고 방 만들기·친구·통화 보임. (안 바뀌면 [다시 확인]) | |
| 12 | 메뉴(☰) | 로그아웃 항목: 왼쪽 **로그인 경로 아이콘**(카카오=노란 말풍선, 구글=G, 애플=검은 사과, 이메일=로그아웃 아이콘) + 이메일 + 오른쪽 로그아웃 아이콘 | |

### 2-3. 기기 인증 **완료** 계정(A)으로 로그인

| # | 확인 | 기대 결과 | 결과 |
|---|---|---|---|
| 13 | 로그인 직후 | 배너 없음, 홈에 참여하기/방 만들기 탭 + 친구·통화 기록·내 ID | |
| 14 | 방 만들기 | 방 만들기 & 입장 가능 | |
| 15 | 메뉴(☰) | 내 ID·친구·통화 기록·설정 + 로그아웃(경로 아이콘 + 이메일) | |

### 2-4. 계정 전환·로그아웃

| # | 확인 | 기대 결과 | 결과 |
|---|---|---|---|
| 16 | 메뉴 [로그아웃] | 확인 창 "로그아웃할까요?" → 로그아웃 → 로그인 전 상태(2-1)로 | |
| 17 | A ↔ B 번갈아 로그인 | 매번 그 계정 상태에 맞게 표시(A=전체, B=인증 필요 배너) | |
| 18 | 앱 완전 종료 후 재실행 | 마지막 로그인 계정과 상태 유지 | |
| 19 | 로그인 화면 버튼 | **애플** 버튼이 맨 위(아이폰만), 그 아래 구글·카카오 | |

### 2-5. 소셜별 로그인

| # | 확인 | 기대 결과 | 결과 |
|---|---|---|---|
| 20 | 이메일 로그인 | 성공 | |
| 21 | 구글 로그인 | 계정 선택 → 성공 — **P2 처리 전이면 ❌ 정상** | |
| 22 | 카카오 로그인(카카오톡 설치) | 카카오톡 인증 → 앱 복귀 → 성공 — **P1 처리 전이면 ❌ 정상** | |
| 23 | 카카오 로그인(카카오톡 미설치) | 웹 카카오계정 로그인 → 성공 | |
| 24 | 애플 로그인 | 성공(최초 1회 이름 제공) | |
| 25 | 소셜 최초 가입 계정 | 약관 동의 창 → 동의 후 로그인 완료 | |

### 2-6. 영어(English)

메뉴 > 앱 언어 > English 로 바꾼 뒤.

| # | 확인 | 기대 결과 | 결과 |
|---|---|---|---|
| 26 | 로그인 전 배너 | "Sign in and verify your device to create rooms, add friends, and call." + **[Sign in]** | |
| 27 | 미인증 계정 배너 | "TV serial registration is required. Please complete it on your phone." + "You can still join meetings." + **[Register]**, **[Check again]** | |
| 28 | 언어 전환 직후(한↔영) | 배너 문구가 바로 그 언어로 바뀜(한글이 섞여 남지 않음) | |
| 29 | [Check again] (미인증) | "Device verification is not confirmed yet." | |
| 30 | 메뉴 로그아웃 | "Sign out" / 확인 창 "Sign out of this account?" | |
| 31 | 로그인 직후 안내(미인증) | "Signed in. Verify your device (TV serial) to unlock all features." | |

### 2-7. 정책 API 파라미터(선택 — 프록시로 확인 가능할 때)

아이폰에서 나가는 요청이 아래와 같아야 한다(마켓앱이 없으므로 `isMobile=Y`, `market_version_code` 없음).

```
GET https://platformtvapi.mychannel.co.kr/gbled/appinterface/tv/1.0/app-policy.asp
    ?app=meeting&brand=<브랜드>&cuid=<브랜드 cuid>&app_version_code=<빌드번호>&isMobile=Y&language=<ko|en>
```

---

## 3. 판정 규칙(참고)

- **티어** = 서버 정책 × 로그인 × 기기 인증
  - `none` → 전체 허용 / `login` → 로그인하면 전체 / `registered` → 로그인 + 기기 인증이어야 전체
- **기기 인증 여부(모바일)** = `GET /api/mobile/me` 의 `tvSerial` 이 비어 있지 않으면 인증.
  - 2026-10-21 실측: `me` 응답에는 `registration` 객체가 **없다**.
  - 한계: **정품 등록(`/my/products`)만 하고 프로필 시리얼을 안 넣은 계정은 미인증으로 보인다** → 서버에 `me` 응답에 `registration{registered,count,source}` 추가 요청 필요.
- 관련 코드: `lib/app_policy.dart`(정책·티어), `lib/access_banner.dart`(배너·메뉴 계정 항목), `lib/mobile_auth.dart`(로그인·me), `lib/login_screen.dart`, `lib/store_login_gate.dart`.

## 4. 결과 공유

실패 항목은 번호 + 스크린샷 + (가능하면) Xcode 콘솔 로그를 같이 남긴다.
