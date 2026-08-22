# 브랜드별 기능 on/off (한 곳에서 관리)

브랜드마다 **CCTV / 친구·통화 / 자막번역** 등 기능을 켜고 끄는 곳은
**`scripts/build_brand.sh` 파일 상단의 "기능 스위치" 표** 한 곳입니다.
거기서 `true`/`false`만 바꾸면 그 브랜드 빌드에 반영됩니다.

## 스위치 항목
| 항목 | 의미 |
|---|---|
| `FRIENDS` | 친구 목록 + 음성/영상 통화 |
| `CALL` | 통화(친구와 함께 켜야 함) |
| `CCTV` | CCTV 공유/시청 (햄버거 메뉴 노출) |
| `TRANSLATION` | 채팅 번역 + 음성 자막 |
| `START_CAMERA` | 입장 시 카메라 자동 켜기(카메라 없는 TV박스는 `false`) |
| `E2EE` | 회의·CCTV 종단간 암호화(모든 참여자 동일 설정 필요, 기본 `false`) |

## 현재 기본값
| 브랜드 | FRIENDS | CALL | CCTV | TRANSLATION |
|---|---|---|---|---|
| prism | ✔ | ✔ | ✔ | ✕ |
| gbled | ✔ | ✔ | ✔ | ✕ |
| viewplus | ✔ | ✔ | ✔ | ✕ |
| mychannel | ✔ | ✔ | ✔ | ✕ |
| ecoglow | ✔ | ✔ | ✔ | ✕ |

> 바꾸려면 `scripts/build_brand.sh` 의 해당 브랜드 줄에서 `true`/`false` 수정.

## 빌드 방법 (Git Bash / 터미널)
```bash
# 한 브랜드
./scripts/build_brand.sh mychannel

# 빌드 후 연결된 기기에 설치까지
./scripts/build_brand.sh prism --install

# 전 브랜드 한번에
./scripts/build_brand.sh all

# 이번 빌드만 E2EE 강제 on (표와 무관하게 테스트용)
./scripts/build_brand.sh mychannel --e2ee
```
결과 APK: `dist/Meeting-<브랜드>.apk`

## 참고
- 이 스위치들은 앱 빌드 시 주입되는 값(`--dart-define`)이라 **빌드 시점에 고정**됩니다.
  (앱 안에서 사용자가 켜고 끄는 게 아니라, 브랜드 빌드마다 정해짐)
- `lib/config.dart` 가 이 값들을 읽습니다(기본값은 모두 꺼짐/안전값).
