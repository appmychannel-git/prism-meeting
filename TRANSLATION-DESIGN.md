# 실시간 번역 설계 (feature/translation)

기준 릴리즈: `v1.0.3` (태그). 이 문서는 **조사·설계** 단계 산출물이며, 구현은
승인 후 이 브랜치에서 진행한다.

---

## 0. 요약 (결론 먼저)

- **1단계 = 채팅 번역**(로드맵 ⑥). 지금 바로 가능, 미디어서버 무관, 리스크 낮음.
- **번역 엔진 = 클라우드 API(Google Cloud Translation v3)로 확정.**
  - 이유: **온디바이스 ML Kit은 키냐르완다(rw)·카자흐어(kk) 미지원.** 타깃 시장
    언어가 빠져 온디바이스 안은 탈락. + ML Kit은 **웹 미지원**(우리는 웹이 핵심).
  - Google Cloud Translation은 **rw·kk 모두 지원**, $20/100만자, **월 50만자 무료**.
- **번역 위치 = 토큰서버(`prism-token-server`, Render) 프록시.**
  - 이유: Google API 키를 클라이언트에 넣으면 유출/도용 위험. 이미 상시 떠 있는
    서버에 `/translate` 하나만 추가하면 키를 서버에만 둘 수 있음.
- **동작 = 수신측 온디맨드 번역.** 각자 "선호 언어"를 고르고, 들어온 메시지의
  언어가 다르면 그때만 번역. 원문 ↔ 번역 토글 제공. 캐시로 비용/지연 최소화.
- **2단계 = 음성 자막 번역**(로드맵 ⑦)은 **별도 후속**. LiveKit Agents(서버) +
  STT 벤더 필요. 대상 언어 STT 지원이 제한적이라 **벤더 검증이 선결 조건**(아래 §5).

---

## 1. 현재 코드 기준점 (삽입 지점)

채팅은 이미 깔끔한 구조라 번역을 얹기 좋다.

- 송신: `room_screen.dart` `_sendChat(text)` → data channel로
  `{"sender","text"}` JSON publish (topic=`_chatTopic`).
- 수신: `_onDataReceived` → 같은 topic이면 파싱 → `_addMessage(ChatMessage(...))`.
- 표시: `chat_panel.dart` `ChatMessage{sender, text, mine}` → `_Bubble`.

→ 번역은 **수신측**에서 `ChatMessage`에 원문/번역/언어 필드를 추가하고, 표시 시
버블에 번역문을 얹는 방식으로 최소 침습 삽입 가능.

## 2. 왜 클라우드 API인가 (조사 결과)

| 항목 | 온디바이스 ML Kit | **Google Cloud Translation v3 (선택)** |
|---|---|---|
| 키냐르완다(rw) | ❌ 미지원 | ✅ 지원 |
| 카자흐어(kk) | ❌ 미지원 | ✅ 지원 |
| 한/영/러 | ✅ | ✅ |
| 웹 지원 | ❌ (Android/iOS만) | ✅ (REST) |
| 비용 | 무료(오프라인) | $20/100만자, **월 50만자 무료** |
| 오프라인 | ✅ | ❌ (네트워크 필요 — 회의앱은 어차피 온라인) |

회의 채팅은 텍스트량이 적어(메시지당 수십~수백자) **월 무료 50만자 안에 충분히
수렴** → 실사용 비용 사실상 0에 가까움. DeepL은 rw·kk 미지원이라 제외.

## 3. 아키텍처

```
[보낸 사람 앱] --(data channel: {sender,text})--> [받는 사람 앱들]
                                                      |
              받는 사람 선호언어 ≠ 메시지 언어이면    |  POST /translate {text, target}
                                                      v
                                        [prism-token-server (Render)]
                                                      |  Google API 키는 여기만
                                                      v
                                        [Google Cloud Translation v3]
                                                      |  {translatedText, detectedSourceLanguage}
                                                      v
                                        받는 사람 앱: 원문+번역 표시(토글)
```

### 3.1 서버 (`prism-token-server` 레포, 별도 작업)
- `POST /translate` 신설: body `{text, target, source?}` →
  `{translatedText, detectedSourceLanguage}`.
- Google Cloud 프로젝트 + Translation API 사용 설정 + 서비스계정 키를 Render 환경변수로.
- 캐시(메모리 LRU, key=`source|target|text`)로 중복 메시지·재요청 비용 절감.
- 남용 방지: 길이 상한(예: 2,000자), 방당/IP 레이트리밋(가벼운 수준).

### 3.2 클라이언트 (이 레포)
- **선호 언어 설정**: 표시이름처럼 로컬 저장(기기 locale 기본값). 회의 화면
  앱바/설정에 언어 선택 메뉴. 후보: `ko, en, ru, rw, kk`(+확장).
- **수신 처리**: 메시지 도착 → (감지된 언어 or 서버 감지) ≠ 내 선호언어이면
  `/translate` 호출 → `ChatMessage`에 번역문 채움.
- **표시**: 버블에 번역문 크게 + "원문 보기" 토글(작게 원문). 내가 보낸 메시지는
  번역 안 함(원문 그대로). 번역 실패 시 원문만 표시(조용히 폴백).
- **캐시**: 클라이언트도 (text→target) 결과 캐시(같은 문장 재번역 방지).

### 3.3 데이터 모델 변경(안)
- `ChatMessage`에 `original`, `translated`(nullable), `srcLang`, `showOriginal`
  추가. 기존 `text`는 표시용(번역 있으면 번역, 없으면 원문)으로 정리.
- data channel payload는 **원문만** 전송(기존 호환). 언어감지는 서버가 수행하거나,
  선택적으로 송신측이 `srcLang` 힌트 추가(경량 최적화, 후순위).

## 4. 단계별 계획 (채팅 번역)

1. **서버**: `prism-token-server`에 `/translate` + Google Translation 연동 + 캐시/상한.
2. **클라 설정**: 선호 언어 선택 UI + 로컬 저장 + 기기 locale 기본값.
3. **클라 수신 번역**: `ChatMessage` 확장 → 수신 시 온디맨드 번역 → 원문/번역 토글.
4. **폴백/UX**: 오프라인·실패 시 원문, 로딩 표시, 캐시.
5. **검증**: 웹/안드로이드에서 ko↔en↔ru↔rw↔kk 왕복 확인, 무료 한도 내 비용 확인.

> 참고: 앱 **UI 다국어화(로드맵 ①, flutter_localizations)**는 "콘텐츠 번역"이 아닌
> 별개 작업. 필요하면 병행하되 본 설계 범위 밖.

## 5. 2단계: 음성 자막 번역 (후속, 선결 검증 필요)

- **구조**: LiveKit Agents(서버 에이전트가 오디오 구독) → STT → 번역 →
  `transcription`으로 자막 송출. **미디어서버/에이전트 인프라 필요** → 자체호스팅
  전환과 묶는 게 자연스러움.
- **대상 언어 STT 현황(조사)**: 카자흐어는 Soniox·Gladia 등 실시간 지원 확인.
  키냐르완다는 지원 벤더가 제한적(Blazescribe·Speechyou 등 니치, 대형 벤더 지원
  불확실). → **어떤 STT 벤더가 rw·kk를 실시간·저지연으로 지원하는지 PoC 검증이
  구현 전 선결 조건.**
- **비용/지연**: STT는 분당 과금 + 번역 과금 이중. 지연·정확도 대상언어별 편차 큼.
- **결론**: 채팅 번역(1단계) 안정화 후, 자체 미디어서버 전환 시점에 벤더 PoC부터.

## 6. 열린 결정 사항 (구현 전 확인)

- 지원 언어 목록 확정: `ko, en, ru, rw, kk` 우선? 그 외 추가?
- Google Cloud 결제 계정/프로젝트 준비 주체(무료 한도 초과 대비 카드 필요).
- 번역 기본 동작: **자동 번역 on**(들어오면 바로 번역) vs **탭하면 번역**(비용/지연 보수적).
- 원문/번역 동시 표시 vs 토글.
