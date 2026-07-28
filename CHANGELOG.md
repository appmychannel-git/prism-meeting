# Changelog

Prism Meeting — Flutter + LiveKit(SFU) 기반 소규모 다자간 화상회의 앱.

버전 표기는 `pubspec.yaml`의 `version:`(예: `1.0.3+4`)을 따릅니다.

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
