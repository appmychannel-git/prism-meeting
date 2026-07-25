# iOS Universal Links — AASA 배포 안내

iOS에서 초대 링크(`https://androidtv.mychannel.co.kr/meeting/?room=...`)를 **Safari 등에서 탭하면 앱이 바로 열리게** 하려면
아래 파일을 **도메인 루트**에 HTTPS로 서빙해야 합니다.

## 배포 위치 (둘 중 하나, 루트 권장)

```
https://androidtv.mychannel.co.kr/.well-known/apple-app-site-association
https://androidtv.mychannel.co.kr/apple-app-site-association
```

- ⚠️ 반드시 **도메인 루트** 기준. `/meeting/` 아래가 아님.
  (Flutter 웹은 `/meeting/`로 배포되므로 이 파일은 웹 빌드에 포함되지 않고, 웹서버에 직접 배치해야 함.)

## 서빙 요구사항 (하나라도 틀리면 동작 안 함)

- **Content-Type**: `application/json` (파일 확장자 없음: `apple-app-site-association`)
- **HTTPS** 필수, 유효한 인증서
- **리다이렉트 금지** (301/302 없이 200으로 바로 응답)
- 인증/쿠키 없이 공개 접근 가능

## 값 설명

- `appIDs`: `N7653V74T8.kr.co.mychannel.meeting.prism`
  - `N7653V74T8` = Apple Developer Team ID
  - `kr.co.mychannel.meeting.prism` = iOS Bundle ID
- `components`: `/meeting/*` 경로의 링크만 앱으로 연결

## 앱 쪽 설정 (이미 완료됨)

- `ios/Runner/Runner.entitlements` 에 `applinks:androidtv.mychannel.co.kr` 추가됨.
- 카카오톡 등 인앱 웹뷰는 Universal Link를 무시하므로, 그 경우는 `web/index.html`의
  커스텀 스킴(`prismmeeting://`) 폴백이 처리한다. (Universal Link ↔ 커스텀 스킴 상호 보완)

## 검증

배포 후:
```
curl -i https://androidtv.mychannel.co.kr/.well-known/apple-app-site-association
```
→ `200`, `Content-Type: application/json`, 위 JSON 내용 그대로 나오면 OK.
Apple 캐시(CDN) 반영에 수 분~수십 분 걸릴 수 있음. 실기기에서 앱 재설치 후 링크 탭으로 확인.
