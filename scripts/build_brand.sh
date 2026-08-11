#!/usr/bin/env bash
# ============================================================================
#  브랜드별 기능 on/off + 빌드  (이 파일이 "브랜드 설정의 한 곳")
# ----------------------------------------------------------------------------
#  사용법 (Git Bash / 터미널에서):
#     ./scripts/build_brand.sh <brand> [--install] [--e2ee]
#  예:
#     ./scripts/build_brand.sh mychannel
#     ./scripts/build_brand.sh prism --install
#     ./scripts/build_brand.sh all           # 전 브랜드 빌드
#
#  ▼▼▼ 브랜드별 기능은 아래 "기능 스위치" 표에서 켜고 끕니다 (true/false) ▼▼▼
#     FRIENDS     : 친구 + 음성/영상 통화
#     CALL        : 통화(친구와 함께 켜야 통화 가능)
#     CCTV        : CCTV 공유/시청
#     TRANSLATION : 채팅 번역 + 음성 자막
#     START_CAMERA: 입장 시 카메라 자동 켜기(카메라 없는 TV박스는 false)
#     E2EE        : 회의·CCTV 종단간 암호화(모든 참여자 동일 설정 필요, 기본 false)
# ============================================================================
set -e

brand_config() {
  case "$1" in
    #          APP_BRAND            FRIENDS CALL  CCTV  TRANSLATION START_CAMERA E2EE
    prism)     APP_BRAND="Prism Meeting"    ; FRIENDS=false; CALL=false; CCTV=false; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    gbled)     APP_BRAND="Gbled Meeting"    ; FRIENDS=false; CALL=false; CCTV=false; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    viewplus)  APP_BRAND="Viewplus Meeting" ; FRIENDS=false; CALL=false; CCTV=false; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    mychannel) APP_BRAND="Mychannel Meeting"; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    *) echo "알 수 없는 브랜드: $1  (prism|gbled|viewplus|mychannel|all)"; exit 1 ;;
  esac
}

build_one() {
  local brand="$1"
  brand_config "$brand"
  echo "== 빌드: $brand =="
  echo "   brand=$APP_BRAND friends=$FRIENDS call=$CALL cctv=$CCTV translation=$TRANSLATION startCamera=$START_CAMERA e2ee=$E2EE_EFFECTIVE"
  flutter build apk --release --flavor "$brand" \
    --dart-define="APP_BRAND=$APP_BRAND" \
    --dart-define=ENABLE_FRIENDS=$FRIENDS \
    --dart-define=ENABLE_CALL=$CALL \
    --dart-define=ENABLE_CCTV=$CCTV \
    --dart-define=SHOW_TRANSLATION=$TRANSLATION \
    --dart-define=START_CAMERA=$START_CAMERA \
    --dart-define=ENABLE_E2EE=$E2EE_EFFECTIVE
  mkdir -p dist
  cp "build/app/outputs/flutter-apk/app-${brand}-release.apk" "dist/Meeting-${brand}.apk"
  echo "   → dist/Meeting-${brand}.apk"
  if [ "$DO_INSTALL" = "1" ]; then
    adb install -r "dist/Meeting-${brand}.apk" || echo "   (install 실패: 기기 연결 확인)"
  fi
}

BRAND="${1:-}"
[ -z "$BRAND" ] && { echo "사용법: ./scripts/build_brand.sh <brand> [--install] [--e2ee]"; exit 1; }
shift || true

DO_INSTALL=0
FORCE_E2EE=0
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --e2ee)    FORCE_E2EE=1 ;;  # 이번 빌드만 E2EE 강제 on(표 설정과 무관)
  esac
done

run_brand() {
  brand_config "$1"
  if [ "$FORCE_E2EE" = "1" ]; then E2EE_EFFECTIVE=true; else E2EE_EFFECTIVE="$E2EE"; fi
  build_one "$1"
}

if [ "$BRAND" = "all" ]; then
  for b in prism gbled viewplus mychannel; do run_brand "$b"; done
else
  run_brand "$BRAND"
fi
