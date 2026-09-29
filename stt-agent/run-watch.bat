@echo off
REM 자막봇(감시 모드) 자동 실행 + 자동 재시작.
REM 작업 스케줄러(로그온 시)로 등록해두면 부팅/로그인 후 자동으로 뜬다.
REM 창을 닫으면 종료된다. 수동 실행도 이 파일을 더블클릭하면 됨.
cd /d %~dp0
:loop
echo [%date% %time%] stt-agent 감시 모드 시작...
.venv\Scripts\python stt_poc.py --watch
echo [%date% %time%] 에이전트 종료(code %errorlevel%). 10초 후 재시작...
timeout /t 10 /nobreak >nul
goto loop
