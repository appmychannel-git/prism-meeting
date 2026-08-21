# Changelog

Prism Meeting — Flutter + LiveKit(SFU) 기반 소규모 다자간 화상회의 앱.

버전 표기는 `pubspec.yaml`의 `version:`(예: `1.0.3+4`)을 따릅니다.

## [Unreleased]

### 공유(카톡·문자 초대) — 신규
- **공유 QR**: 옆에 있는 휴대폰이 QR을 찍으면 **공유 페이지**가 열려, 친구추가/회의/앱설치
  링크를 카카오톡·문자로 **멀리 있는 사람에게 전송**(TV는 메신저를 못 보내므로 휴대폰이 중계).
  - 내 ID 화면 상단 "카톡·문자로 초대", 회의 초대창 "카톡·문자로 공유", 좌측 메뉴 "앱 공유".
- **공유 페이지(정적)** `share_page/index.html`: 제목·메시지·대상링크(`t/m/u`)를 받아
  Web Share(카톡·문자) + 복사 제공. 서버 `/meeting-cctv/share/` 에 배포.
  앱 설치 링크는 `/meeting-cctv/download/Meeting-<brand>.apk`(브랜드별 자동 지정).
- **App Links 경로 정리**: `pathPrefix "/meeting"` → 정확 경로 `/meeting/`,`/meeting-cctv/`만
  앱으로. 하위 경로(`/share/`,`/download/`)는 앱이 아니라 브라우저로 열리게 함.

### 브랜드
- **ECO GLOW Meeting** 브랜드 추가(`kr.co.mychannel.meeting.ecoglowkc`, 기능 전부 off).

### 기기 호환
- 외장(탈착식) 카메라 기기: QR 라이브 스캔이 안 될 때(검은 화면) 갤러리 선택/코드 입력 안내.

## [1.0.5+5] - 2026-08

번역 이후, **멀티 브랜드 + 친구·통화 + CCTV**를 main에 통합한 릴리즈.

### 브랜드/멀티빌드
- 한 코드베이스 → 브랜드별 **flavor 빌드**: prism / gbled / viewplus / mychannel.
  기능 on/off(친구·통화·CCTV·번역·카메라·E2EE)를 `scripts/build_brand.sh` + `BRANDS.md`
  한 곳에서 관리(빌드 시 `--dart-define` 주입).
- 브랜드별 아이콘/스플래시/앱이름(`applicationId`·`appLabel`).

### 친구·통화 (모바일)
- 친구 추가: 내 ID QR(이름 필수)·짧은 코드·초대 링크, "나를 추가한 사람" 추천, 차단/거절.
- 1:1 음성·영상 통화: 전용 통화 UI, FCM 수신벨(잠금화면 풀스크린 `CATEGORY_CALL`),
  커스텀 벨소리(ring_classic)·반복·진동·링백톤, 스피커/이어피스(근접센서), 카메라 전환.
- presence(온라인/통화중) + 통화기록 + 부재중 알림, 수락형(친구요청 승인) 설정.
- **재설치·업데이트에도 신원 유지**: `ANDROID_ID` 기반(브랜드=패키지명으로 분리) +
  서버에서 친구목록 복구. 딥링크: 내 ID QR(uid/name)로 앱 열면 친구추가+통화 시트.

### CCTV
- CCTV 허브(시청/녹화 탭), 카메라 송출(기기 고정 코드 + 6자리 비번),
  시청(5분 계속 확인 / 30초 자동중지), **원격 켜기**(대기 TV를 FCM으로 깨움),
  **송출 절전 모드**(미조작 30초 → 미리보기 off + 밝기 최소, 송출은 유지).

### 보안
- 커스텀 토큰 로그인 + Firestore 규칙(소유자/당사자 한정), `fcmToken` 격리(`deviceTokens`).
- CCTV 핀 6자리 + 서버 브루트포스 제한 + 핀 헤더 전송(URL 미노출).
- 회의 비밀번호는 QR/링크에 담지 않고 수동 입력. 미디어 E2EE 옵션(기본 off, 비번=공유키).

### 기기 호환/버그
- 카메라 없는/외장 카메라 기기 UI 멈춤 회피(`videoInputs` 확인, `START_CAMERA` 플래그).
- mychannel 적응형 아이콘 순환참조 수정, 웹 초대 링크를 현재 접속 경로에서 자동 유도.

## [1.0.3+4] - 2026-07-28

번역 작업 착수 전 **개발버전 릴리즈 기준점**. 이 태그(`v1.0.3`)를 base로
실시간 번역 기능을 별도 브랜치(`feature/translation`)에서 개발합니다.

### 회의 코어
- LiveKit(SFU) 다자간 회의: simulcast + adaptiveStream + dynacast, TV 부하 대비
  `maxVisibleTiles`(기본 6) 렌더 상한.
- 갤러리 뷰(6명/페이지 페이지네이션 ◀▶) + 발표자 뷰(발언자 메인/핀).
- 채팅(data channel) — 넓은 화면(PC·TV 가로)은 영상 옆 인라인 패널.
- 마이크·카메라·음소거 표시, 발언자 하이라이트, "영상 수신 끄기(저사양)",
  재연결 배너, 회의 중 화면 유지(wakelock).

### 방 관리
- 방 만들기/참여(없는 방 404), 랜덤/지정 방코드, 비공개 방(입장코드 6자리,
  LiveKit 방 메타데이터로 서버 검증).
- 방장 회의 종료(전원 퇴장 + 안내), identity/name 분리(유령 참가자 방지).
- 방 수명 정책: 중복 생성 거부(409), 무입장 10분 종료, 종료 후 3분 방장 재생성
  예약, 생성 1시간 후 자동 종료(회원 차등 스캐폴드).

### 초대/입장
- 초대 링크(웹 `?room=&pin=` 자동 입장) + Android App Links(assetlinks 검증)
  + 카카오 등 인앱브라우저 `intent://` 자동 실행.
- QR 초대(회의 화면 QR, TV→폰 스캔 입장).
- 초대 링크 입장 전 이름 팝업(확인/랜덤=입장, 취소=참여폼), 회의 중 이름 변경.

### 화면 공유
- 웹/PC(getDisplayMedia)·폰 송출, 전 플랫폼 수신, 자동 프레젠테이션 뷰.
- 안드로이드 mediaProjection FGS(알림 권한 선요청 + 1회 재시도) 안정화.

### 플랫폼/기기 호환
- 웹 + 안드로이드(폰/TV/태블릿) + iOS 플랫폼 추가(화면공유 Broadcast Extension·
  Universal Links).
- 저가 안드로이드 박스: H.264 코덱 고정, Impeller(Vulkan) 끄기(Skia),
  카메라 enable 타임아웃, rebuild throttle.
- USB 웹캠(UVC) 부분 지원(Camera2 external 노출 시 열거/선택/전환).

### 브랜딩/배포
- applicationId `kr.co.mychannel.meeting.prism`, 입장화면 "Powered by 마이채널".
- 토큰서버 Render 상시 배포, 웹 `androidtv.mychannel.co.kr/meeting/`.

### 버그 수정
- 백그라운드 재실행 시 QR/딥링크 재적용(resume 폴백) + QR 다이얼로그 오버플로우.
