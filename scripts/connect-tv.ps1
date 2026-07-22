# Eco Smart Display(태블릿TV) 무선 ADB 재연결 도우미
#
# 사용법:  ./scripts/connect-tv.ps1
# TV의 mDNS 이름이 세션마다 (2)(3)... 으로 바뀌어도 시리얼로 찾아
# 안정적인 IP:5555 로 다시 연결해 준다. 실행 후 안내되는 flutter 명령을 쓰면 됨.

$ErrorActionPreference = 'Stop'

# TV 시리얼(고정). 다른 TV면 이 값만 교체.
$serial = 'C861D00C3B6C'

Write-Host "[connect-tv] TV(mDNS) 탐색 중..." -ForegroundColor Cyan
$line = & adb devices |
    Select-String "$serial.*_adb-tls-connect\._tcp" |
    Select-Object -First 1
if (-not $line) {
    Write-Host "TV를 찾지 못했습니다. TV에서 '무선 디버깅'을 켜고 PC와 같은 Wi-Fi인지 확인하세요." -ForegroundColor Red
    exit 1
}
$mdns = ($line.ToString() -split '\s+')[0]

$raw = & adb -s $mdns shell ip -f inet addr show wlan0 2>&1
$ip = [regex]::Match(($raw -join "`n"), 'inet (\d+\.\d+\.\d+\.\d+)').Groups[1].Value
if (-not $ip) {
    Write-Host "TV의 IP를 읽지 못했습니다. TV 연결 상태를 확인하세요." -ForegroundColor Red
    exit 1
}

Write-Host "[connect-tv] TV IP = $ip -> tcpip 5555 전환 후 연결" -ForegroundColor Cyan
& adb -s $mdns tcpip 5555 | Out-Null
Start-Sleep -Seconds 3
& adb connect "$($ip):5555"

Write-Host ""
Write-Host "TV 준비 완료. 아래 명령으로 실행하세요:" -ForegroundColor Green
Write-Host "  flutter run -d $($ip):5555 --dart-define=LK_TOKEN_URL=<토큰서버주소>/token" -ForegroundColor Yellow
