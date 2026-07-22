# Prism Meeting

소규모 다자간 화상회의 앱 (프로토타입).
**웹(노트북) · 안드로이드 폰 · 안드로이드TV/디스플레이/태블릿** 을 하나의 Flutter 코드베이스로 지원.

---

## 아키텍처 한눈에

| 구성 | 선택 | 이유 |
|------|------|------|
| 미디어 | **WebRTC + SFU** | 다자간에서 저사양 기기(TV) 부하를 낮춤 |
| SFU 엔진 | **LiveKit** | 웹/Flutter/Android 전 플랫폼 SDK, 자체호스팅 이전 용이 |
| 서버 | **LiveKit Cloud** (프로토타입) → 추후 자체호스팅 | 지금은 서버 구축 0일, 앱에만 집중 |
| 앱 | **Flutter 단일 코드베이스** | 웹+안드로이드+TV 통합 유지보수 |

다자간 최적화(= Zoom과 같은 원리)는 코드에 이미 적용됨:
- `simulcast` — 고/중/저 화질 동시 송신 → 수신자별 최적 선택
- `adaptiveStream` — 작게 보이는 영상은 저화질로 자동
- `dynacast` — 아무도 안 보는 화질은 송신 중단
- **TV 부하 상한** — 한 화면 렌더 인원을 `maxVisibleTiles`(기본 6)로 제한 → 방 정원(12명)과 무관하게 부하 고정

---

## 빠른 시작 (약 5분)

> LiveKit Cloud의 Sandbox 토큰 서버는 서비스 종료되어, 표준 방식인
> **"API 키 + 경량 토큰 서버(token-server/)"** 로 구성합니다. 자체호스팅 이전 시에도 그대로 사용.

### 1) LiveKit Cloud에서 값 3개 확보 (무료)
1. https://cloud.livekit.io 가입 → 프로젝트 생성
2. **URL**: 프로젝트의 `wss://...livekit.cloud` (Settings/General)
3. **API Key / Secret**: 좌측 **"API keys"** 탭에서 발급

### 2) 토큰 서버 실행 (Node)
```powershell
cd token-server
npm install
$env:LIVEKIT_URL="wss://<프로젝트>.livekit.cloud"
$env:LIVEKIT_API_KEY="<API Key>"
$env:LIVEKIT_API_SECRET="<API Secret>"
node index.js      # -> listening on :3000
```
(자세한 내용: `token-server/README.md`)

### 3) 앱 실행 (토큰 서버 주소 주입)
```bash
# 웹 (같은 PC)
flutter run -d chrome --dart-define=LK_TOKEN_URL=http://localhost:3000/token

# 안드로이드 폰 / TV (같은 Wi-Fi, PC의 LAN IP 사용)
flutter devices
flutter run -d <device-id> --dart-define=LK_TOKEN_URL=http://192.168.10.20:3000/token
```

> 토큰 서버 주소 없이도 앱은 뜨며, 이때는 "직접 입력" 모드에서 서버 URL + 토큰을
> 수동으로 넣어 테스트할 수 있습니다(데모/디버깅용).

### 4) 다자간 테스트
- 여러 기기(노트북 웹 / 폰 / 디스플레이)에서 **같은 방 이름**으로 입장하면 서로 보임
- 같은 기기라도 브라우저 탭 여러 개로 인원 테스트 가능

---

## 빌드 산출물 만들기 (거래처 전달용)

```bash
# 웹 정적 파일 (아무 웹서버에 올리면 됨, HTTPS 필수)
flutter build web

# 안드로이드 APK (토큰 서버 주소는 실제 배포 주소로)
flutter build apk --release --dart-define=LK_TOKEN_URL=http://<토큰서버주소>:3000/token
# 결과물: build/app/outputs/flutter-apk/app-release.apk
```

- **웹은 반드시 HTTPS**(또는 localhost)에서 열어야 카메라/마이크가 동작합니다.
- APK는 안드로이드 폰/TV/태블릿 공용. TV엔 `LEANBACK_LAUNCHER` 등록되어 TV 런처에 아이콘이 뜹니다.

---

## 프로젝트 구조

```
lib/
  config.dart             # Sandbox ID, 방 정원, TV 렌더 상한 등 설정
  connection_service.dart # 접속 토큰 발급 (Sandbox / 수동). 자체서버 전환 시 여기만 교체
  join_screen.dart        # 입장 화면 (방/이름/접속방식)
  room_screen.dart        # 회의 화면 (다자간 그리드 + 컨트롤 + TV 부하 상한)
android/app/src/main/AndroidManifest.xml  # 카메라/마이크 권한 + TV(leanback) 설정
```

---

## 나중에: 자체 미디어 서버로 이전

앱과 토큰 서버 코드는 그대로. **바꾸는 것은 서버 주소/키뿐**:
1. LiveKit 서버 + coturn(TURN)을 Docker로 기동 (`docker run livekit/generate`)
2. `token-server` 의 `LIVEKIT_URL` / `API_KEY` / `API_SECRET` 를 자체 서버 값으로 교체
3. 앱은 변경 없음 (여전히 토큰 서버 `/token` 호출)

Cloud → 자체호스팅은 환경변수 교체 수준이라 매몰비용이 없습니다.

---

## 프로토타입 범위 / 다음 단계

**현재 구현:**
- 방 입장 / 다자간 영상 — **갤러리 뷰**(스크롤 없이 화면에 꽉 채우는 그리드, 방향 자동 대응) + **발표자 뷰**(발언자 자동 스포트라이트 / 썸네일 탭하여 고정)
- 마이크·카메라 토글, **참가자별 마이크 음소거 표시**, **발언자 초록 테두리 강조**
- **회의 중 텍스트 채팅** (LiveKit 데이터 채널, 안 읽음 뱃지)
- **나가기 → 입장 화면 복귀**
- **안드로이드TV 리모컨(D-pad) 대응** — 입력칸 ↑/↓ 포커스 이동, 버튼·썸네일 포커스, 시작 포커스
- **저가/고장 기기 호환** — H.264 코덱 고정, Impeller(Vulkan) off, 카메라 없어도 입장, **"영상 수신 끄기(저사양)" 모드**
- 전 플랫폼 빌드(웹/안드로이드폰/TV·태블릿)

**향후 후보(기존 Securet 앱에서 참고 가능):**
- 화면 공유
- 채팅 확장(이모지 반응, 이미지/파일 공유)
- 수신 전화 벨/푸시 (FCM)
- **USB 웹캠(UVC) 지원** — 카메라 없는 TV 박스용 (참고 앱이 이 방식 사용)
- 참가자 페이지네이션(12명↑ 시 페이지 전환)
- 인증/로그인, 자체 토큰 서버, 자체호스팅 이전

---

## 거래처 데모용 외부 APK 만들기

현재까지 구현분을 외부(사내망 밖)에서도 보여줄 때:

1. **토큰 서버 실행** (데스크탑) — `token-server/README.md` 참고
2. **무료 터널로 외부 공개** (cloudflared, 계정·결제 불필요):
   ```powershell
   cloudflared tunnel --url http://localhost:3000
   # → https://xxxx.trycloudflare.com 발급
   ```
3. **APK 빌드** (터널 주소를 넣어):
   ```powershell
   flutter build apk --release --dart-define=LK_TOKEN_URL=https://xxxx.trycloudflare.com/token
   # → build/app/outputs/flutter-apk/app-release.apk
   ```
4. 이 APK를 거래처 기기에 설치하면 어디서든 접속됩니다.

> ⚠️ **주의**: 터널·토큰 서버는 **데스크탑이 켜져 있는 동안만** 동작합니다(임시 시연용).
> 거래처가 상시 독립적으로 쓰려면 토큰 서버를 무료 호스팅(Render/Railway 등)에 올려
> **고정 주소**로 바꾸면 됩니다.
