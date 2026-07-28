# 채팅 번역 활성화 절차 (Google Cloud + Render)

코드는 완성됨. **번역 기능을 켜려면 아래 계정 작업이 필요**하다(개발자가 대신
불가). 완료 전까지 앱의 "번역" 탭은 "번역 실패(키 미설정)"로만 뜬다.

계정: `appmychannel@gmail.com`

---

## 1. Google Cloud — Translation API 키 발급

1. https://console.cloud.google.com 에 `appmychannel@gmail.com` 로 로그인.
2. 상단에서 **프로젝트 생성**(예: `prism-meeting`) 후 선택.
3. **결제 사용 설정(필수)**: "결제" → 결제 계정 연결(카드 등록).
   - ⚠️ Cloud Translation은 **무료 한도(월 50만자)를 쓰려 해도 결제 계정이
     필수**다. 회의 채팅량은 이 무료 한도 안에 들어가 실제 청구는 거의 0.
4. **API 사용 설정**: "API 및 서비스" → "라이브러리" → **Cloud Translation API**
   검색 → **사용(Enable)**.
5. **API 키 생성**: "API 및 서비스" → "사용자 인증 정보" → "사용자 인증 정보
   만들기" → **API 키**. 생성된 키 문자열 복사.
6. (보안 권장) 그 키의 "API 제한사항" → **Cloud Translation API 만 허용**으로 제한.

## 2. Render — 환경변수 등록

1. https://dashboard.render.com → `prism-token-server` 서비스.
2. **Environment** → **Add Environment Variable**:
   - Key: `GOOGLE_TRANSLATE_API_KEY`
   - Value: 위에서 만든 API 키
3. 저장 → 자동 재배포. 로그에 `번역 key set = yes` 뜨면 정상.

## 3. 서버 코드 배포 (아직 안 했다면)

`prism-token-server` 레포에 `/translate` 커밋이 반영돼야 한다.

```bash
cd token-server
git push origin main   # Render 자동 재배포
```

> 이 푸시는 **프로덕션 토큰 서버를 재배포**한다. `/translate` 추가는 기존
> `/token` 동작에 영향 없는 순수 추가 변경이지만, 배포 타이밍은 직접 정하도록
> 로컬 커밋만 해두었다.

## 4. 확인

```bash
curl -s -X POST https://prism-token-server.onrender.com/translate \
  -H "Content-Type: application/json" \
  -d '{"text":"안녕하세요","target":"en"}'
# → {"translatedText":"Hello","detectedSourceLanguage":"ko"}
```

앱에서: 회의 입장 → 채팅 → 상대가 보낸 메시지의 **"번역"** 탭 → 원문 아래
번역문 표시. 채팅 헤더의 🌐 드롭다운으로 대상 언어 변경.

---

## 비용 메모

- 요금: **$20 / 100만자**, **월 50만자 무료**(언어 수와 무관, 글자수 기준).
- 탭 번역(온디맨드) + 서버/클라 캐시라 실제 호출량은 매우 적음 → 사실상 무료 범위.
- 상한: 한 번에 `TRANSLATE_MAX_CHARS`(기본 2000자)까지. env로 조절 가능.
