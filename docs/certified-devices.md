# 검증 기기(Verified Device) 체크

버전 정보를 **5번 연속 탭**하면 "기기 검증 여부" 안내창이 뜨고, 현재 기기가
**검증된 기기**인지 서버 API로 확인한다. 새 기기에 앱을 설치했을 때 카메라 등
일부 기능이 동작하지 않을 수 있어, 우리가 실제로 확인한 기기만 "검증"으로 표시한다.

- 검증 기기 목록은 **전적으로 서버 API로 관리**한다(앱에 하드코딩 없음).
- 새 기기를 검증하면 **API의 JSON만 수정**하면 되고, **앱 재빌드가 필요 없다.**

> 용어: UI 문구는 "검증"을 쓰지만, API 엔드포인트 파일명은 기존에 올린
> `certified-devices.asp` 를 그대로 유지한다.

---

## 1. API 명세

정적(또는 동적) JSON 응답. `brand`·`app` 쿼리로 앱 종류를 구분한다.

```
GET https://platformtvapi.mychannel.co.kr/gbled/appinterface/tv/1.0/certified-devices.asp?brand=<brand>&app=<app>
```

| 파라미터 | 값 | 설명 |
|---|---|---|
| `brand` | `viewplus`, `gbled`, `freedom`, `mychannel` … | 브랜드 슬러그 |
| `app`   | `meeting` 또는 `cctv` | 앱 종류(미팅앱 / CCTV 전용앱) |

예: 미팅앱 = `...?brand=viewplus&app=meeting`, CCTV앱 = `...?brand=viewplus&app=cctv`

### 응답 JSON

```json
{
  "devices": [
    { "manufacturer": "WQi",   "model": "Gm81",         "label": "27형 스탠드 TV (Gm81)" },
    { "manufacturer": "Ehlel", "model": "Defender D23", "label": "Defender D23" }
  ]
}
```

| 필드 | 필수 | 설명 |
|---|---|---|
| `model` | ✅ | 기기 모델명. **검증 판정에 쓰는 유일한 키**(대소문자 무시). `ro.product.model` 값 |
| `manufacturer` | 선택 | 제조사. **표시용**(판정에는 사용 안 함). `ro.product.manufacturer` 값 |
| `label` | 선택 | 목록에 보여줄 사람이 읽기 좋은 이름. 없으면 `model` 표시 |

- `devices` 배열만 있으면 된다. (최상위가 배열 `[ ... ]` 이어도 앱이 처리함)
- 응답 앞뒤 공백/개행은 무시된다. `Content-Type` 은 JSON 권장.
- 웹에서도 받으므로 **CORS 허용**(`Access-Control-Allow-Origin: *`) 필요.

---

## 2. 새 기기 검증(추가) 방법

1. 대상 기기에서 모델명·제조사 확인:
   ```bash
   adb shell getprop ro.product.model          # 예: Gm81
   adb shell getprop ro.product.manufacturer   # 예: WQi
   ```
2. 기능(카메라·통화·CCTV 등)이 정상 동작하는지 확인.
3. API JSON의 `devices` 배열에 한 줄 추가 후 재업로드:
   ```json
   { "manufacturer": "WQi", "model": "새모델명", "label": "보여줄 이름" }
   ```
4. 끝. 앱 재설치/재빌드 없이 다음 실행부터 "검증된 기기"로 표시된다.

> 판정은 `model` 만 비교하므로(대소문자 무시), **`model` 값이 기기의 `ro.product.model`
> 과 정확히 일치**해야 한다. `manufacturer` 는 표기가 달라도 판정에 영향 없다.

---

## 3. 앱(클라이언트) 동작

1. 홈 화면 우측 상단 **버전 텍스트(`v1.0.x`)를 2초 이내 5번 탭** → 안내창.
2. 앱이 `getDeviceInfo`(네이티브)로 `manufacturer`/`model` 조회.
3. 위 API를 받아와(타임아웃 6초) `devices` 목록과 비교:
   - 목록에 **같은 `model`(대소문자 무시)** 이 있으면 → **검증된 기기**.
   - 없으면 → **검증되지 않은 기기**(사용은 가능, 일부 기능 제한 가능 안내).
4. API 실패/빈 목록이면 목록이 비어 아무 기기도 검증으로 표시되지 않는다(하드코딩 없음).
5. 안내창의 **"검증 기기 목록"** 버튼 → 받아온 목록 전체 표시(현재 기기는 "현재 기기" 배지).

### 안내창 문구(한/영)

| 키 | 한국어 | English |
|---|---|---|
| 제목 | 기기 검증 여부 | Device verification |
| 현재 기기 | 이 기기: `<manufacturer> <model>` | This device: … |
| 검증됨 | 검증된 기기입니다 | This device is verified |
| 미검증 | 검증되지 않은 기기입니다 | Not a verified device |
| 미검증 설명 | 사용은 가능하지만 일부 기능(카메라 등)이 동작하지 않을 수 있습니다. | You can still use it, but some features (e.g. camera) may not work. |
| 목록 버튼 | 검증 기기 목록 | Verified devices |

---

## 4. 구현 참고 (이 앱 기준)

- 모듈: [`lib/supported_devices.dart`](../lib/supported_devices.dart)
  - `SupportedDevices.current()` → `(manufacturer, model, supported)`
  - `VersionBadge` 위젯 → 버전 텍스트 자리에 넣으면 5탭 감지 + 안내창 호출
  - `showSupportedDeviceDialog(context)` / `showSupportedDeviceListDialog(context)`
- URL 조립(설정): [`lib/config.dart`](../lib/config.dart)
  - `CERT_API_BASE`(기본 위 .asp 주소), `CERT_BRAND`, `CERT_APP` 을 dart-define 으로 받음.
  - `certifiedDevicesUrl => '$certApiBase?brand=$certBrand&app=$certApp'`
  - ⚠️ URL 에 `&` 를 **직접 dart-define 값으로 넣지 말 것**(Windows `flutter.bat` 가
    `&` 를 명령 구분자로 해석해 빌드가 깨짐). 반드시 base·brand·app 을 나눠 전달하고
    앱에서 조립한다.
- 빌드 스크립트: [`scripts/build_brand.sh`](../scripts/build_brand.sh), [`scripts/build_web.sh`](../scripts/build_web.sh)
  - `*cctv` 브랜드 → `CERT_BRAND=${brand%cctv}`, `CERT_APP=cctv`
  - 그 외 → `CERT_BRAND=$brand`, `CERT_APP=meeting`
- 기기 정보 네이티브: MethodChannel `app/fullscreen` 의 `getDeviceInfo`
  → `{ manufacturer, model }` 반환(안드로이드).

### 다른 앱에 이식할 때 체크리스트

1. 홈 화면 버전 텍스트를 탭 카운터(2초 내 5회)로 감싸 안내창 호출.
2. 기기 `model`/`manufacturer` 조회 수단 확보(네이티브 or 플러그인).
3. 위 API를 `brand`/`app` 파라미터로 호출 → `devices[].model` 과 기기 `model` 비교.
4. 안내창 + 목록창 UI(위 문구) 구현.
5. 빌드 시 `brand`/`app` 주입(URL에 `&` 직접 넣지 않기).
