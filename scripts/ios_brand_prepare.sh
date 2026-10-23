#!/usr/bin/env bash
# ============================================================================
#  iOS 브랜드 "준비"만 (빌드/원복 안 함) — Xcode 에서 직접 Archive·업로드할 때.
#    ./scripts/ios_brand_prepare.sh <brand>
#  동작: 번들ID·이름·아이콘·URL스킴·Firebase plist·구글/카카오 주입을 적용하고,
#        flutter build ios --config-only 로 dart-define(USE_STORE_LOGIN 등)을
#        Generated.xcconfig 에 심는다(= Xcode Archive 가 이 설정으로 빌드).
#  ⚠ ios/ 가 브랜드 상태로 남는다(원복 안 함). 끝나면: git checkout -- ios/
# ============================================================================
set -e
cd "$(dirname "$0")/.."
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export PATH="$HOME/development/flutter/bin:$PATH"
source scripts/brands.sh

BRAND="${1:-}"
[ -z "$BRAND" ] && { echo "사용법: ./scripts/ios_brand_prepare.sh <brand>"; exit 1; }

brand_config "$BRAND"
BASE="$(brand_base_url "$BRAND")"
BUNDLE="$(brand_package "$BRAND")"
SCHEME="$(brand_scheme "$BRAND")"
WITHEXT=0; [ "$BRAND" = "prism" ] && WITHEXT=1
echo "== prepare(Xcode): $BRAND  bundle=$BUNDLE  name=$APP_BRAND =="

# 1) Firebase plist
if [ -f "ios/firebase/$BRAND/GoogleService-Info.plist" ]; then
  cp "ios/firebase/$BRAND/GoogleService-Info.plist" ios/Runner/GoogleService-Info.plist
elif [ "$BRAND" != "prism" ]; then
  echo "!! ios/firebase/$BRAND/GoogleService-Info.plist 없음 — 배포 필수."; exit 1
fi

# 2) 프로젝트 변형(prism 은 원본 그대로)
[ "$BRAND" != "prism" ] && ruby scripts/ios_brand_apply.rb "$BRAND" "$BUNDLE" "$APP_BRAND" "$WITHEXT" "$SCHEME"

# 3) 아이콘
if [ -f "assets/icon/brand_$BRAND.png" ]; then
  printf 'flutter_launcher_icons:\n  ios: true\n  remove_alpha_ios: true\n  image_path: "assets/icon/brand_%s.png"\n' "$BRAND" > .brand_icon.yaml
  dart run flutter_launcher_icons -f .brand_icon.yaml >/dev/null
  rm -f .brand_icon.yaml
fi

# 4) dart-define 을 Generated.xcconfig 에 심기(빌드는 안 함) — Xcode Archive 가 사용.
flutter build ios --config-only --release \
  --dart-define=LK_TOKEN_URL=https://prism-token-server.onrender.com/token \
  --dart-define="APP_BRAND=$APP_BRAND" \
  --dart-define=ENABLE_FRIENDS=$FRIENDS --dart-define=ENABLE_CALL=$CALL --dart-define=ENABLE_CCTV=$CCTV \
  --dart-define=SHOW_TRANSLATION=$TRANSLATION --dart-define=START_CAMERA=$START_CAMERA --dart-define=ENABLE_E2EE=$E2EE \
  --dart-define=CCTV_ONLY=${CCTV_ONLY:-false} \
  --dart-define=USE_STORE_LOGIN=${USE_STORE_LOGIN:-false} \
  --dart-define="SPLASH_IMAGE=${SPLASH_IMAGE:-}" --dart-define="SPLASH_BG=${SPLASH_BG:-}" \
  --dart-define="DEFAULT_LANG=${DEFAULT_LANG:-}" --dart-define=SERVER_STT=${SERVER_STT:-false} \
  --dart-define="INVITE_BASE_URL=$BASE" --dart-define="SHARE_BASE_URL=${BASE}share/"

echo ""
echo "== 준비 완료: $BRAND =="
echo "  이제 Xcode 에서: ios/Runner.xcworkspace 열기 → Runner 스킴 + 'Any iOS Device'"
echo "  → Product > Archive → Distribute App > App Store Connect > Upload"
echo "  끝나면 원복:  git checkout -- ios/  (+ rm -f ios/Runner/GoogleService-Info.plist 는 gitignore 라 그대로 둬도 됨)"
