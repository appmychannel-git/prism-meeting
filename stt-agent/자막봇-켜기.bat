@echo off
chcp 65001 >nul
title 자막봇 (freedom 서버 자막) - 이 창을 닫으면 꺼집니다
REM 바탕화면 바로가기용: freedom 회의에 서버 자막(Azure Speech)을 붙이는 감시 모드를 켠다.
REM 필요할 때만 켜고, 끝나면 창을 닫는다(켜 있는 동안 freedom 회의 시간만큼 과금).
REM 다른 브랜드·CCTV·1:1 통화 방에는 들어가지 않는다(WATCH_ONLY_APPS=freedom).
cd /d %~dp0
if not exist .venv\Scripts\python.exe (
  echo [오류] .venv 가 없습니다. 이 폴더에서 아래를 한 번 실행하세요:
  echo   python -m venv .venv
  echo   .venv\Scripts\python -m pip install -r requirements.txt
  pause
  exit /b 1
)
echo ============================================================
echo  자막봇 켜짐 - freedom 회의방에 자동으로 자막을 붙입니다.
echo  끝나면 이 창을 닫으세요 (닫으면 자막봇 종료, 비용 중지).
echo ============================================================
call run-watch.bat
