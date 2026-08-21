import 'dart:math';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// Prism Meeting - 앱 전역 설정
///
/// [거래처 전달 / 테스트 준비]
/// 접속 토큰은 함께 제공되는 경량 토큰 서버(token-server/)에서 발급합니다.
/// (LiveKit Cloud의 Sandbox 토큰 서버는 서비스 종료되어, 표준 방식인
///  "API 키 + 자체 토큰 서버"로 구성합니다. 자체호스팅 이전 시에도 그대로 사용.)
///
/// 준비 순서:
///   1. https://cloud.livekit.io 프로젝트에서 URL / API Key / API Secret 확보
///      - URL:       Settings > Project 의 wss://... 주소
///      - API Key/Secret: 좌측 "API keys" 탭에서 발급
///   2. token-server/ 를 그 값으로 실행 (token-server/README 참고)
///   3. 아래 [tokenServerUrl] 을 토큰 서버 주소로 지정하거나 실행 시 주입:
///        --dart-define=LK_TOKEN_URL=http://[PC의 LAN IP]:3000/token
class AppConfig {
  /// 앱 표시 버전. 입장 화면 우측 상단에 노출한다.
  /// pubspec.yaml 의 version 과 함께 올린다(수동 동기화).
  static const String appVersion = '1.0.5';

  /// 앱 표시 브랜드명(브라우저 타이틀 + 입장화면 제목).
  /// 기본 'Prism Meeting'. 거래처 시연 등 브랜드를 숨길 땐
  /// --dart-define=APP_BRAND=Meeting 로 덮어쓴다.
  static const String appBrand = String.fromEnvironment(
    'APP_BRAND',
    defaultValue: 'Prism Meeting',
  );

  /// 번역 엔진을 빌드별로 강제 지정. ''(기본)=서버 기본 엔진.
  /// 카자흐스탄 빌드는 --dart-define=LK_TRANSLATE_PROVIDER=azure 로 Azure 사용.
  static const String translateProvider = String.fromEnvironment(
    'LK_TRANSLATE_PROVIDER',
    defaultValue: '',
  );

  /// 입장 시 카메라 자동 켜기(기본 true).
  /// 카메라가 없거나 고장난 기기(일부 TV박스·디스플레이)는 카메라 open이
  /// 네이티브에서 멈춰 앱이 굳는다. 그런 기기용 빌드는
  /// --dart-define=START_CAMERA=false 로 자동 켜기를 끈다(입장 후 수동 켜기 가능).
  static const bool startCamera = bool.fromEnvironment(
    'START_CAMERA',
    defaultValue: true,
  );

  // ─────────────────────────────────────────────────────────────
  // 기능 플래그 (브랜드/빌드별 on·off). 빌드 시 --dart-define=<NAME>=true|false
  // ─────────────────────────────────────────────────────────────

  /// 채팅 번역·음성 자막 기능 노출 여부. **기본 숨김(false)** — 전 브랜드.
  /// 번역을 쓰는 거래처 빌드만 --dart-define=SHOW_TRANSLATION=true 로 켠다.
  static const bool showTranslation = bool.fromEnvironment(
    'SHOW_TRANSLATION',
    defaultValue: false,
  );

  /// 미디어 종단간 암호화(E2EE). 회의·CCTV에서 비밀번호를 공유키로 사용.
  /// **기본 off** — 켜려면 모든 참여자(앱/웹)가 같은 빌드여야 하고 브라우저 지원 필요.
  /// --dart-define=ENABLE_E2EE=true 로 켠다.
  static const bool e2ee = bool.fromEnvironment(
    'ENABLE_E2EE',
    defaultValue: false,
  );

  // 아래 3개는 "회원 없이 기기 UUID로 식별 + 푸시"가 필요한 기능이라
  // 모바일(Android/iOS) 전용이다. PC(윈도/맥)·웹에선 기기 식별/푸시 수단이
  // 없어 자동 비활성된다([supportsDeviceFeatures]). 기본 off.
  static const bool _enableCctv =
      bool.fromEnvironment('ENABLE_CCTV', defaultValue: false);
  static const bool _enableFriends =
      bool.fromEnvironment('ENABLE_FRIENDS', defaultValue: false);
  static const bool _enableCall =
      bool.fromEnvironment('ENABLE_CALL', defaultValue: false);

  /// 기기 UUID 기반 기능(친구·통화·CCTV)을 이 플랫폼에서 쓸 수 있는가.
  /// 회원 없이 기기 고유값으로 식별하므로, 안정적 기기 식별·푸시가 없는
  /// PC(윈도/맥)·웹에선 false → 해당 기능들 강제 비활성.
  static bool get supportsDeviceFeatures =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// 실제 활성 여부 = 빌드 플래그 AND 플랫폼 지원.
  /// CCTV는 기기 UUID/FCM이 필요 없고(방+비밀번호 기반), 시청은 PC/웹도 대상이라
  /// supportsDeviceFeatures 를 요구하지 않는다(빌드 플래그만).
  static bool get cctvEnabled => _enableCctv;
  static bool get friendsEnabled => _enableFriends && supportsDeviceFeatures;
  static bool get callEnabled => _enableCall && supportsDeviceFeatures;

  /// 토큰 서버의 /token 엔드포인트 주소.
  ///   - 웹(같은 PC) 테스트:  http://localhost:3000/token
  ///   - 폰/TV 등 다른 기기:  http://[PC의 LAN IP]:3000/token  (예: http://192.168.10.20:3000/token)
  /// 비워두면 앱은 "직접 입력(수동)" 모드로만 동작합니다.
  static const String tokenServerUrl = String.fromEnvironment(
    'LK_TOKEN_URL',
    // 기본값 내장 → --dart-define 없이 (안드로이드 스튜디오에서) 빌드해도 동작.
    // 필요 시 --dart-define=LK_TOKEN_URL=... 로 덮어쓸 수 있음.
    defaultValue: 'https://prism-token-server.onrender.com/token',
  );

  /// 채팅 번역 엔드포인트 주소(POST /translate).
  /// 기본은 토큰 서버 주소의 끝 `/token` 을 `/translate` 로 바꾼 값.
  /// 필요 시 --dart-define=LK_TRANSLATE_URL=... 로 덮어쓸 수 있음.
  static const String _translateUrlOverride = String.fromEnvironment(
    'LK_TRANSLATE_URL',
    defaultValue: '',
  );
  static String get translateServerUrl {
    if (_translateUrlOverride.isNotEmpty) return _translateUrlOverride;
    const suffix = '/token';
    if (tokenServerUrl.endsWith(suffix)) {
      return '${tokenServerUrl.substring(0, tokenServerUrl.length - suffix.length)}/translate';
    }
    return tokenServerUrl;
  }

  /// 채팅 번역 지원 언어: 코드 -> 표시 이름(각 언어 고유 표기).
  /// Google Cloud Translation 은 언어당 추가 비용이 없어 폭넓게 지원.
  static const Map<String, String> supportedLanguages = {
    'ko': '한국어',
    'en': 'English',
    'kk': 'Қазақ',
    'ru': 'Русский',
    'rw': 'Ikinyarwanda',
    'fr': 'Français',
    'ja': '日本語',
    'zh': '中文',
    'es': 'Español',
    'de': 'Deutsch',
    'ar': 'العربية',
  };

  /// 받은 메시지를 번역할 대상(선호) 언어.
  /// 빈 문자열('')이면 "사용 안 함"(번역 끔) — 기본값.
  /// 언어를 선택하면 그때부터 받은 메시지를 자동 번역한다.
  /// (앱 실행 중 유지. 채팅 패널 드롭다운에서 변경. 재시작 시 '사용 안 함'으로 초기화.)
  static String _targetLang = '';
  static String get targetLanguage => _targetLang;
  static set targetLanguage(String code) {
    if (code.isEmpty || supportedLanguages.containsKey(code)) _targetLang = code;
  }

  /// 기본 방 이름 (입장 화면 기본값)
  static const String defaultRoomName = 'prism-demo';

  /// 한 화면에 동시에 렌더링할 최대 참가자 수(자기 자신 포함).
  /// 저사양 안드로이드TV/디스플레이 보호용 상한선.
  /// 방 정원(최대 12명)과는 무관하며, 실제 부하를 이 값으로 묶습니다.
  static const int maxVisibleTiles = 6;

  /// 안드로이드TV/디스플레이 등 큰 화면 판별 기준(픽셀 폭).
  static const double tvBreakpointWidth = 1100;

  /// 초대 링크 기본 주소. 링크 형식: [base]?room=[코드]
  /// - 웹: 현재 접속 중인 실제 경로에서 자동 유도 → 어느 경로에 올려도
  ///   (/meeting/, /meeting-kz/ 등) 그 경로로 초대 링크가 생성된다.
  /// - 네이티브(앱): 고정값(초대는 웹 링크로 연다). 빌드별로
  ///   --dart-define=INVITE_BASE_URL=... 로 덮어쓸 수 있음.
  static const String _inviteBaseNative = String.fromEnvironment(
    'INVITE_BASE_URL',
    defaultValue: 'https://androidtv.mychannel.co.kr/meeting/',
  );
  static String get inviteBaseUrl {
    if (kIsWeb) {
      final b = Uri.base; // 예: https://.../meeting-kz/?room=... (쿼리 제거)
      return '${b.origin}${b.path}';
    }
    return _inviteBaseNative;
  }

  /// 초대 링크. 보안상 **비밀번호는 링크/QR에 담지 않는다**(직접 입력하도록).
  /// pin 파라미터는 호출부 호환을 위해 남겨두지만 무시한다.
  static String inviteLink(String room, {String? pin}) {
    final params = <String, String>{'room': room};
    final base = inviteBaseUrl;
    final sep = base.contains('?') ? '&' : '?';
    return '$base$sep${Uri(queryParameters: params).query}';
  }

  /// 공유 페이지 주소. TV가 띄운 "공유 QR"을 휴대폰으로 찍으면 이 페이지가 열리고,
  /// 거기서 대상 링크(친구추가/회의/앱설치)를 카톡·문자로 재전송할 수 있다.
  /// (TV는 카톡·문자를 못 보내므로, 옆의 휴대폰이 중계 역할)
  /// --dart-define=SHARE_BASE_URL=... 로 덮어쓸 수 있음.
  static const String shareBaseUrl = String.fromEnvironment(
    'SHARE_BASE_URL',
    defaultValue: 'https://androidtv.mychannel.co.kr/meeting-cctv/share/',
  );

  /// 앱 설치용 APK 다운로드 주소(구글스토어 미등록 → 직접 다운로드 유도).
  /// 브랜드별로 다를 수 있어 빌드 시 --dart-define=APK_URL=... 로 지정.
  static const String apkUrl = String.fromEnvironment(
    'APK_URL',
    defaultValue:
        'https://androidtv.mychannel.co.kr/meeting-cctv/download/Meeting-mychannel.apk',
  );

  /// 공유 페이지 URL 생성: 제목(t)·메시지(m)·대상링크(u)를 쿼리로 실어 보낸다.
  /// 이 URL을 QR로 만들어 두면, 휴대폰이 찍었을 때 공유 페이지가 열려
  /// [targetUrl]을 카톡·문자로 보낼 수 있다.
  static String sharePageUrl({
    required String title,
    required String message,
    required String targetUrl,
  }) {
    final base = shareBaseUrl;
    final sep = base.contains('?') ? '&' : '?';
    final q = Uri(queryParameters: {
      't': title,
      'm': message,
      'u': targetUrl,
    }).query;
    return '$base$sep$q';
  }

  /// 짧고 타이핑 가능한 랜덤 방 코드 생성 (예: abc-def-hij).
  /// 헷갈리는 문자(0 o 1 l i) 제외 → 추측 불가하면서도 입력하기 쉬움.
  static String generateRoomCode() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random();
    String grp(int n) =>
        List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
    return '${grp(3)}-${grp(3)}-${grp(3)}';
  }

  /// 이 기기의 고정 식별값(identity). 표시 이름과 분리한다.
  /// 앱 실행 중 한 번만 생성되어 유지 → 이름을 바꿔 재접속해도 identity는 동일하므로
  /// 서버가 "같은 사람 재접속"으로 보고 이전 세션을 즉시 교체(유령 참가자 방지).
  static String? _deviceId;
  static String get deviceIdentity {
    _deviceId ??=
        'u${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(100000)}';
    return _deviceId!;
  }
}
