import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// 방 접속에 필요한 서버 URL + 참가자 토큰.
class ConnectionDetails {
  final String serverUrl;
  final String token;
  const ConnectionDetails({required this.serverUrl, required this.token});
}

/// LiveKit 접속 정보를 가져오는 서비스.
///
/// 두 가지 방식을 지원한다:
///  1) Server  - 우리 토큰 서버(token-server/)의 /token 에서 발급 (표준/프로덕션 경로)
///  2) Manual  - 서버 URL + 토큰을 직접 입력 (데모/디버깅용)
///
/// 자체호스팅으로 전환해도 이 파일은 그대로. 토큰 서버의 LIVEKIT_URL 만
/// 자체 서버 주소로 바꾸면 된다.
class ConnectionService {
  /// 앱 패키지명(applicationId) 캐시. 토큰 요청 시 표식으로 전송한다.
  /// (서버는 나중에 이 값으로 옛/미승인 앱을 차단할 수 있다 — 차단 로직은 추후.)
  static String? _cachedAppId;
  static Future<String> _appId() async {
    if (_cachedAppId != null) return _cachedAppId!;
    try {
      final info = await PackageInfo.fromPlatform();
      _cachedAppId = info.packageName; // 예: kr.co.mychannel.meeting.prism
    } catch (_) {
      _cachedAppId = '';
    }
    return _cachedAppId!;
  }

  /// 토큰 서버에서 접속 정보 발급.
  /// [tokenServerUrl] 예: http://192.168.10.20:3000/token
  static Future<ConnectionDetails> fetchFromServer({
    required String tokenServerUrl,
    required String roomName,
    required String participantName,
    required String identity,
    String? pin,
    bool create = false,
  }) async {
    final params = {
      'room': roomName,
      'name': participantName,
      'identity': identity,
    };
    if (pin != null && pin.isNotEmpty) params['pin'] = pin;
    if (create) params['create'] = 'true';
    // 앱 패키지명 전송(옛 앱 차단용 표식). 값이 없으면 생략.
    final appId = await _appId();
    if (appId.isNotEmpty) params['appId'] = appId;
    final uri = Uri.parse(tokenServerUrl).replace(queryParameters: params);

    final http.Response resp;
    try {
      resp = await http.get(uri);
    } catch (e) {
      throw Exception('토큰 서버에 연결할 수 없습니다: $tokenServerUrl\n서버 실행/주소를 확인하세요.\n$e');
    }

    if (resp.statusCode != 200) {
      // 서버가 준 error 메시지를 깔끔히 표시
      String msg = '접속 실패 (HTTP ${resp.statusCode})';
      try {
        final j = jsonDecode(resp.body);
        if (j is Map && j['error'] != null) msg = j['error'].toString();
      } catch (_) {}
      throw Exception(msg);
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = data['serverUrl'] as String?;
    final token = (data['participantToken'] ?? data['token']) as String?;
    if (url == null || token == null) {
      throw Exception('응답에 serverUrl/participantToken 이 없습니다: ${resp.body}');
    }
    return ConnectionDetails(serverUrl: url, token: token);
  }

  /// 방장이 회의 종료 → 서버가 방 삭제(전원 퇴장).
  /// tokenServerUrl 의 /token 을 /end 로 바꿔 호출한다.
  static Future<void> endRoom({
    required String tokenServerUrl,
    required String roomName,
    required String identity,
  }) async {
    final endUrl = tokenServerUrl.replaceFirst(RegExp(r'/token/?$'), '/end');
    final uri = Uri.parse(endUrl).replace(queryParameters: {
      'room': roomName,
      'identity': identity,
    });
    try {
      await http.get(uri).timeout(const Duration(seconds: 8));
    } catch (_) {
      // 종료 요청 실패해도 로컬 disconnect는 진행
    }
  }

  /// 수동 입력 방식(서버 URL + 토큰 직접 붙여넣기).
  static ConnectionDetails manual({
    required String serverUrl,
    required String token,
  }) {
    return ConnectionDetails(serverUrl: serverUrl.trim(), token: token.trim());
  }
}
