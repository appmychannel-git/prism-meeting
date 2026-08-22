#!/usr/bin/env bash
# ============================================================================
#  브랜드별 웹(Flutter Web) 빌드 → 서버 /apps/meeting/<brand>/ 에 올릴 소스 생성.
# ----------------------------------------------------------------------------
#  사용법:
#     ./scripts/build_web.sh <brand>     # 한 브랜드
#     ./scripts/build_web.sh all         # 전 브랜드
#
#  결과: dist/web/<brand>/  (이 폴더 내용을 서버 /apps/meeting/<brand>/ 에 업로드)
#        - 회의 웹(index.html 등) : base-href=/apps/meeting/<brand>/
#        - share/index.html        : 공유 페이지(카톡·문자 링크 전송)
#        - download/               : (여기에 Meeting-<brand>.apk 를 넣어 배포)
#
#  참고: 웹에선 친구·통화(기기 UUID/FCM 필요)가 자동 비활성(플랫폼 미지원).
#        CCTV '시청'과 회의는 동작. 그래서 웹 빌드도 플래그는 동일하게 넘긴다.
# ============================================================================
set -e
cd "$(dirname "$0")/.."
source "scripts/brands.sh"

# Git Bash(MSYS)가 "/apps/meeting/..." 같은 앞-슬래시 인자를 윈도우 경로로 바꿔
# --base-href 가 깨진다(예: C:/Program Files/Git/apps/...). 경로 변환을 끈다.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

build_web_one() {
  local brand="$1"
  brand_config "$brand"
  local base; base="$(brand_base_url "$brand")"        # https://.../apps/meeting/<brand>/
  local href="/apps/meeting/${brand}/"                  # base-href(경로만)
  echo "== 웹 빌드: $brand  (base-href=$href) =="

  flutter build web --release \
    --base-href "$href" \
    --dart-define="APP_BRAND=$APP_BRAND" \
    --dart-define=ENABLE_FRIENDS=$FRIENDS \
    --dart-define=ENABLE_CALL=$CALL \
    --dart-define=ENABLE_CCTV=$CCTV \
    --dart-define=SHOW_TRANSLATION=$TRANSLATION \
    --dart-define=START_CAMERA=$START_CAMERA \
    --dart-define=ENABLE_E2EE=$E2EE \
    --dart-define=SHARE_BASE_URL="${base}share/" \
    --dart-define=APK_URL="${base}download/Meeting-${brand}.apk"

  local out="dist/web/${brand}"
  rm -rf "$out"
  mkdir -p "$out"
  cp -r build/web/* "$out/"
  # 공유 페이지 동봉(브라우저로 열림 — 앱이 아님)
  mkdir -p "$out/share"
  cp share_page/index.html "$out/share/index.html"
  # APK 배포 폴더 자리(여기에 dist/Meeting-<brand>.apk 를 복사해 올린다)
  mkdir -p "$out/download"
  if [ -f "dist/Meeting-${brand}.apk" ]; then
    cp "dist/Meeting-${brand}.apk" "$out/download/Meeting-${brand}.apk"
    echo "   + download/Meeting-${brand}.apk 포함"
  else
    echo "   (안내) dist/Meeting-${brand}.apk 없음 → build_brand.sh 로 APK 먼저 빌드하면 자동 포함"
  fi
  echo "   → $out  (서버 /apps/meeting/${brand}/ 에 업로드)"
}

BRAND="${1:-}"
[ -z "$BRAND" ] && { echo "사용법: ./scripts/build_web.sh <brand|all>"; exit 1; }

if [ "$BRAND" = "all" ]; then
  for b in $BRAND_LIST; do build_web_one "$b"; done
else
  build_web_one "$BRAND"
fi
