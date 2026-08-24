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
# ============================================================================

# 전 브랜드 목록(all 빌드 순서)
BRAND_LIST="prism gbled viewplus mychannel ecoglow"

brand_config() {
  case "$1" in
    #          APP_BRAND            FRIENDS CALL  CCTV  TRANSLATION START_CAMERA E2EE
    prism)     APP_BRAND="Prism Meeting"    ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    gbled)     APP_BRAND="Gbled Meeting"    ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    viewplus)  APP_BRAND="Viewplus Meeting" ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    mychannel) APP_BRAND="Mychannel Meeting"; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    ecoglow)   APP_BRAND="ECO GLOW Meeting" ; FRIENDS=true ; CALL=true ; CCTV=true ; TRANSLATION=false; START_CAMERA=true;  E2EE=false ;;
    *) echo "알 수 없는 브랜드: $1  ($BRAND_LIST|all)"; exit 1 ;;
  esac
}

# 브랜드별 서버 배포 base 경로. 딥링크(App Links)가 브랜드마다 달라야 "그 브랜드
# 앱"으로만 열린다. 구조: androidtv.mychannel.co.kr/apps/meeting/<brand>/
brand_base_url() { echo "https://androidtv.mychannel.co.kr/apps/meeting/$1/"; }

# 브랜드별 안드로이드 패키지명(=applicationId). 웹의 카톡 인앱브라우저 intent://
# 자동실행에서 "그 브랜드 앱"을 지정하는 데 쓴다.
brand_package() {
  case "$1" in
    prism)     echo "kr.co.mychannel.meeting.prism" ;;
    gbled)     echo "kr.co.mychannel.meeting.gbled" ;;
    viewplus)  echo "kr.co.mychannel.meeting.viewplus" ;;
    mychannel) echo "kr.co.mychannel.meeting" ;;
    ecoglow)   echo "kr.co.mychannel.meeting.ecoglowkc" ;;
    *) echo "kr.co.mychannel.meeting.$1" ;;
  esac
}

# 브랜드별 iOS 커스텀 스킴(카톡 인앱웹뷰에서 Universal Link가 안 먹으므로 스킴으로 앱 실행).
# iOS 앱이 이 스킴을 등록해야 한다(예: prism=prismmeeting).
brand_scheme() { echo "${1}meeting"; }
