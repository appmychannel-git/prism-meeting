#!/usr/bin/env bash
# ============================================================================
#  브랜드 설정 "한 곳" — APK 빌드(build_brand.sh)와 웹 빌드(build_web.sh)가 공유.
# ----------------------------------------------------------------------------
#   FRIENDS     : 친구 + 음성/영상 통화
#   CALL        : 통화(친구와 함께 켜야 통화 가능)
#   CCTV        : CCTV 공유/시청
#   TRANSLATION : 채팅 번역 + 음성 자막
#   START_CAMERA: 입장 시 카메라 자동 켜기(카메라 없는 TV박스는 false)
#   E2EE        : 회의·CCTV 종단간 암호화(모든 참여자 동일 설정 필요, 기본 false)
#   CCTV_ONLY   : CCTV 전용 앱(홈이 CCTV 화면, 회의/친구/번역 숨김)
# ============================================================================

# 전 브랜드 목록(all 빌드 순서). *cctv = CCTV 전용 앱(패키지 kr.co.mychannel.cctv.<brand>).
BRAND_LIST="prism gbled viewplus mychannel ecoglow gbledcctv viewpluscctv freedom freedomcctv"

brand_config() {
  CCTV_ONLY=false
  DEFAULT_LANG=""   # 브랜드 기본 UI 언어(빈 값=기기 언어). 예: freedom="en"
  case "$1" in
    #             APP_BRAND            FRIENDS CALL  CCTV  TRANSLATION START_CAMERA E2EE
    prism)        APP_BRAND="Prism Meeting"    ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    gbled)        APP_BRAND="글로벌미팅"    ; FRIENDS=true ; CALL=true ; CCTV=false ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    viewplus)     APP_BRAND="Viewplus Meeting" ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    mychannel)    APP_BRAND="Mychannel Meeting"; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    ecoglow)      APP_BRAND="ECO GLOW Meeting" ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    # ── 프리덤미디어(Freedom Media, 카자흐스탄) — 기본 언어 영어 ──
    freedom)      APP_BRAND="Freedom Meeting"  ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=true ; START_CAMERA=true;  E2EE=false; DEFAULT_LANG="en" ;;
    # ── CCTV 전용 앱(회의/친구 없음, 홈=CCTV) ──
    gbledcctv)    APP_BRAND="글로벌 CCTV"     ; FRIENDS=false; CALL=false; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false; CCTV_ONLY=true ;;
    viewpluscctv) APP_BRAND="Viewplus CCTV"   ; FRIENDS=false; CALL=false; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false; CCTV_ONLY=true ;;
    freedomcctv)  APP_BRAND="Freedom CCTV"     ; FRIENDS=false; CALL=false; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false; CCTV_ONLY=true; DEFAULT_LANG="en" ;;
    *) echo "알 수 없는 브랜드: $1  ($BRAND_LIST|all)"; exit 1 ;;
  esac
}

# 브랜드별 서버 배포 base 경로. 딥링크(App Links)가 브랜드마다 달라야 "그 브랜드
# 앱"으로만 열린다. 회의=/apps/meeting/<brand>/, CCTV전용=/apps/cctv/<brand>/.
brand_base_url() {
  case "$1" in
    *cctv) echo "https://androidtv.mychannel.co.kr/apps/cctv/${1%cctv}/" ;;
    *)     echo "https://androidtv.mychannel.co.kr/apps/meeting/$1/" ;;
  esac
}

# 브랜드별 안드로이드 패키지명(=applicationId).
brand_package() {
  case "$1" in
    prism)        echo "kr.co.mychannel.meeting.prism" ;;
    gbled)        echo "kr.co.mychannel.meeting.gbled" ;;
    viewplus)     echo "kr.co.mychannel.meeting.viewplus" ;;
    mychannel)    echo "kr.co.mychannel.meeting" ;;
    ecoglow)      echo "kr.co.mychannel.meeting.ecoglowkc" ;;
    freedom)      echo "kr.co.mychannel.meeting.freedom" ;;
    gbledcctv)    echo "kr.co.mychannel.cctv.gbled" ;;
    viewpluscctv) echo "kr.co.mychannel.cctv.viewplus" ;;
    freedomcctv)  echo "kr.co.mychannel.cctv.freedom" ;;
    *) echo "kr.co.mychannel.meeting.$1" ;;
  esac
}

# 브랜드별 iOS 커스텀 스킴(카톡 인앱웹뷰용).
brand_scheme() {
  case "$1" in
    *cctv) echo "${1%cctv}cctv" ;;   # 예: gbledcctv → gbledcctv
    *)     echo "${1}meeting" ;;
  esac
}
