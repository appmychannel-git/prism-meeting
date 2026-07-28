import 'dart:math';
import 'dart:ui' as ui;

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
  static const String appVersion = '1.0.3';

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

  /// 내가 받은 메시지를 번역할 대상(선호) 언어. 기본값은 기기 언어.
  /// (앱 실행 중 유지. 채팅 패널에서 변경 가능. 재시작 시 기기 언어로 초기화.)
  static String? _targetLang;
  static String get targetLanguage => _targetLang ??= _defaultLanguage();
  static set targetLanguage(String code) {
    if (supportedLanguages.containsKey(code)) _targetLang = code;
  }

  static String _defaultLanguage() {
    final code = ui.PlatformDispatcher.instance.locale.languageCode
        .toLowerCase();
    return supportedLanguages.containsKey(code) ? code : 'en';
  }

  /// 기본 방 이름 (입장 화면 기본값)
  static const String defaultRoomName = 'prism-demo';

  /// 한 화면에 동시에 렌더링할 최대 참가자 수(자기 자신 포함).
  /// 저사양 안드로이드TV/디스플레이 보호용 상한선.
  /// 방 정원(최대 12명)과는 무관하며, 실제 부하를 이 값으로 묶습니다.
  static const int maxVisibleTiles = 6;

  /// 안드로이드TV/디스플레이 등 큰 화면 판별 기준(픽셀 폭).
  static const double tvBreakpointWidth = 1100;

  /// 초대 링크 기본 주소 (웹 배포 위치). 링크 형식: [base]?room=[코드]
  static const String inviteBaseUrl =
      'https://androidtv.mychannel.co.kr/meeting/';

  static String inviteLink(String room, {String? pin}) {
    final params = <String, String>{'room': room};
    if (pin != null && pin.isNotEmpty) params['pin'] = pin;
    return '$inviteBaseUrl?${Uri(queryParameters: params).query}';
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
