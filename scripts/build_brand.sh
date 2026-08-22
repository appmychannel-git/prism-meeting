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

# 브랜드 설정은 공용 파일에서(APK/웹 빌드가 같은 설정 공유).
source "$(dirname "$0")/brands.sh"

build_one() {
  local brand="$1"
  brand_config "$brand"
  echo "== 빌드: $brand =="
  # 브랜드별 배포 경로(딥링크/공유/APK). 구조: /apps/meeting/<brand>/
  #   - <base>            : 회의 웹 + 딥링크 진입점(친구추가/회의 링크)
  #   - <base>share/      : 공유 페이지(카톡·문자 전송, 브라우저로 열림)
  #   - <base>download/…  : 앱(APK) 다운로드
  local base_url; base_url="$(brand_base_url "$brand")"
  local invite_url="$base_url"
  local share_url="${base_url}share/"
  local apk_url="${base_url}download/Meeting-${brand}.apk"
  echo "   brand=$APP_BRAND friends=$FRIENDS call=$CALL cctv=$CCTV translation=$TRANSLATION startCamera=$START_CAMERA e2ee=$E2EE_EFFECTIVE"
  echo "   base=$base_url"
  flutter build apk --release --flavor "$brand" \
    --dart-define="APP_BRAND=$APP_BRAND" \
    --dart-define=ENABLE_FRIENDS=$FRIENDS \
    --dart-define=ENABLE_CALL=$CALL \
    --dart-define=ENABLE_CCTV=$CCTV \
    --dart-define=SHOW_TRANSLATION=$TRANSLATION \
    --dart-define=START_CAMERA=$START_CAMERA \
    --dart-define=ENABLE_E2EE=$E2EE_EFFECTIVE \
    --dart-define=INVITE_BASE_URL=$invite_url \
    --dart-define=SHARE_BASE_URL=$share_url \
    --dart-define=APK_URL=$apk_url
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
  for b in $BRAND_LIST; do run_brand "$b"; done
else
  run_brand "$BRAND"
fi
