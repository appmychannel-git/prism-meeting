# 서버측 STT PoC (LiveKit + Azure Speech)

기기 자체 음성인식이 없는 TV·셋톱·저가 태블릿에서도 자막이 되게 하는 **서버측
STT**의 검증용 PoC. 방에 '자막봇'으로 참가해 참가자 음성을 Azure로 받아쓰고,
앱이 이미 쓰는 자막 형식(topic `caption`, `{sender,text,lang,final}`)으로 발행한다.
→ **앱(클라이언트) 코드 수정 없이** 자막이 뜬다.

> 이건 PoC입니다. 지연·정확도·비용을 실측해 "갈지 말지"를 정하는 용도.
> 서버 배포 없이 **노트북에서 바로** 실행합니다.

## 1. 준비물
- Python 3.9+
- LiveKit URL / API Key / Secret (토큰 서버가 쓰는 값과 동일)
- Azure Speech 키 + 지역
  - portal.azure.com → "Speech service" 리소스 생성(무료 F0 티어 가능)
  - "키 및 엔드포인트"에서 **KEY1** 과 **지역(Location/Region)** 확인 (예: `koreacentral`)

## 2. 설치
```bash
cd stt-agent
python -m venv .venv
# Windows(Git Bash): source .venv/Scripts/activate
# macOS/Linux:       source .venv/bin/activate
pip install -r requirements.txt
```

## 3. 키 설정 (채팅에 붙이지 말 것 — 로컬 .env 에만)
```bash
cp .env.example .env
# .env 를 열어 LIVEKIT_*, AZURE_SPEECH_* 값 채우기
# STT_CANDIDATES: 한국 테스트=ko-KR / 카자흐=kk-KZ,ru-RU
```

## 4. 실행
```bash
python stt_poc.py --room <회의방코드>
```
- `<회의방코드>` = 실제 회의에서 쓰는 방 코드(참가자와 같은 방).
- 실행하면 봇이 방에 들어가 대기. 참가자가 말하면 콘솔에 인식 결과가 찍히고,
  같은 방의 클라이언트에서 **자막을 켜면** 그 자막이 화면에 뜬다.

## 5. 무엇을 볼 것인가 (PoC 판단 기준)
- **지연**: 말한 뒤 자막까지 몇 초? (목표: 1~2초 내 부분자막)
- **정확도**: 특히 카자흐(kk)·한국어(ko) 실사용 문장.
- **비용**: Azure 포털 사용량 = 대략 스트림·시간당. 회의 길이 대비 감.
- **다국어 자동감지**: 후보 여러 개일 때 언어 전환이 잘 잡히는지.

## 6. PoC 이후 (운영으로 가면)
- 이 스크립트를 LiveKit **Agents 워커**로 승격(자동 디스패치: 자막 켠 방에만 투입).
- 상시 실행 위치: Render "Background Worker" / Fly.io / 소형 VM (공개 포트 불필요).
- 클라 게이팅: 서버 STT 켠 방/빌드에선 **기기 로컬 STT를 끄기**(중복 자막 방지).
  → `--dart-define=SERVER_STT=true` 또는 방 metadata 로 제어(후속 작업).

## 알려진 PoC 한계 (운영 전 다듬을 것)
- 봇이 **일반 참가자로 보임**(빈 타일). 운영에선 hidden 참가자 또는 클라에서
  `captions-bot` identity 를 참가자 목록/타일에서 제외.
- 앱의 실시간(중간) 자막은 발화자 구분에 참가자 identity 를 쓰는데, 봇이 대신
  발행하면 모두 봇 identity 로 묶인다(동시 발화 시 중간자막 겹칠 수 있음).
  → 운영에선 payload 의 화자 식별자를 우선 쓰도록 클라 소폭 수정.
- 로컬 STT 되는 기기(폰)가 자막을 켜면 로컬+서버 자막이 **중복**될 수 있다
  → 위 SERVER_STT 게이팅으로 해결.
