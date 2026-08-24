#!/usr/bin/env bash
# ============================================================================
#  iOS 브랜드 빌드 (안드로이드 build_brand.sh 의 iOS 판)
# ----------------------------------------------------------------------------
#  사용법 (Mac 터미널):
#     ./scripts/build_ios_brand.sh <brand> [--codesign]
#  예:
#     ./scripts/build_ios_brand.sh gbled            # 컴파일 검증(서명 없음)
#     ./scripts/build_ios_brand.sh gbled --codesign # 배포용 IPA (dist/ios/)
#
#  동작:
#   - prism 은 저장소 원본 상태(확장 포함) 그대로 빌드.
#   - 그 외 브랜드는 빌드 전에 번들ID·표시이름·아이콘·URL스킴·Firebase plist 를 주입하고,
#     화면공유 Broadcast Extension 은 제거(수신/시청은 됨, 송출만 보류)한 뒤 빌드.
#   - 빌드 후 `git checkout -- ios/` 로 항상 원복(prism 기준). 실패해도 trap 으로 원복.
#
#  준비물: 브랜드별 Firebase plist 를 아래 위치에 두어야 함(prism 제외).
#     ios/firebase/<brand>/GoogleService-Info.plist
# ============================================================================
set -e
cd "$(dirname "$0")/.."
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export PATH="$HOME/development/flutter/bin:$PATH"
source scripts/brands.sh

BRAND="${1:-}"
[ -z "$BRAND" ] && { echo "사용법: ./scripts/build_ios_brand.sh <brand|all> [--codesign]"; exit 1; }
shift || true
CODESIGN=0
for a in "$@"; do [ "$a" = "--codesign" ] && CODESIGN=1; done

restore() { git checkout -- ios/ 2>/dev/null || true; rm -f .brand_icon.yaml;
  find ios/Runner/Assets.xcassets -maxdepth 1 -name "AppIcon-*.appiconset" -exec rm -rf {} + 2>/dev/null || true; }

build_one() {
  local BRAND="$1"
  brand_config "$BRAND"                 # → APP_BRAND, FRIENDS, CALL, CCTV, TRANSLATION, START_CAMERA, E2EE
  local BASE; BASE="$(brand_base_url "$BRAND")"
  local BUNDLE SCHEME WITHEXT
  case "$BRAND" in
    prism)     BUNDLE=kr.co.mychannel.meeting.prism;     SCHEME=prismmeeting;     WITHEXT=1 ;;
    gbled)     BUNDLE=kr.co.mychannel.meeting.gbled;     SCHEME=gbledmeeting;     WITHEXT=0 ;;
    viewplus)  BUNDLE=kr.co.mychannel.meeting.viewplus;  SCHEME=viewplusmeeting;  WITHEXT=0 ;;
    mychannel) BUNDLE=kr.co.mychannel.meeting;           SCHEME=mychannelmeeting; WITHEXT=0 ;;
    ecoglow)   BUNDLE=kr.co.mychannel.meeting.ecoglowkc; SCHEME=ecoglowmeeting;   WITHEXT=0 ;;
    *) echo "알 수 없는 브랜드: $BRAND"; return 1 ;;
  esac
  echo "== iOS 빌드: $BRAND  (bundle=$BUNDLE  ext=$WITHEXT  name=$APP_BRAND) =="

  trap 'restore' EXIT

  # 1) Firebase plist 배치
  if [ -f "ios/firebase/$BRAND/GoogleService-Info.plist" ]; then
    cp "ios/firebase/$BRAND/GoogleService-Info.plist" ios/Runner/GoogleService-Info.plist
  elif [ "$BRAND" != "prism" ]; then
    if [ "$CODESIGN" = "1" ]; then
      echo "!! ios/firebase/$BRAND/GoogleService-Info.plist 없음 — Firebase 콘솔에서 받아 넣어주세요(배포 필수)."; return 1
    fi
    echo "(경고) $BRAND Firebase plist 없음 → 컴파일 검증만(런타임 Firebase 미동작)."
  fi

  # 2) 프로젝트 변형 (prism 은 원본)
  [ "$BRAND" != "prism" ] && ruby scripts/ios_brand_apply.rb "$BRAND" "$BUNDLE" "$APP_BRAND" "$WITHEXT" "$SCHEME"

  # 3) 아이콘: 기본 AppIcon 덮어쓰기(파일명이 flavor 패턴 아님 → 기본 카탈로그 갱신)
  if [ -f "assets/icon/brand_$BRAND.png" ]; then
    printf 'flutter_launcher_icons:\n  ios: true\n  remove_alpha_ios: true\n  image_path: "assets/icon/brand_%s.png"\n' "$BRAND" > .brand_icon.yaml
    dart run flutter_launcher_icons -f .brand_icon.yaml >/dev/null
    rm -f .brand_icon.yaml
  fi

  # 4) clean 빌드(브랜드 간 확장 잔재 방지)
  flutter clean >/dev/null
  local DEFINES=(
    --dart-define=LK_TOKEN_URL=https://prism-token-server.onrender.com/token
    --dart-define="APP_BRAND=$APP_BRAND"
    --dart-define=ENABLE_FRIENDS=$FRIENDS --dart-define=ENABLE_CALL=$CALL --dart-define=ENABLE_CCTV=$CCTV
    --dart-define=SHOW_TRANSLATION=$TRANSLATION --dart-define=START_CAMERA=$START_CAMERA --dart-define=ENABLE_E2EE=$E2EE
    --dart-define="INVITE_BASE_URL=$BASE" --dart-define="SHARE_BASE_URL=${BASE}share/"
  )
  if [ "$CODESIGN" = "1" ]; then
    flutter build ipa "${DEFINES[@]}"
    mkdir -p dist/ios
    cp build/ios/ipa/*.ipa "dist/ios/Meeting-$BRAND.ipa" && echo "   → dist/ios/Meeting-$BRAND.ipa"
  else
    flutter build ios --no-codesign "${DEFINES[@]}"
  fi

  restore
  trap - EXIT
  echo "== 완료: $BRAND =="
}

if [ "$BRAND" = "all" ]; then
  for b in $BRAND_LIST; do build_one "$b"; done
else
  build_one "$BRAND"
fi
