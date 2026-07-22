import 'dart:convert';
import 'package:http/http.dart' as http;

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
  /// 토큰 서버에서 접속 정보 발급.
  /// [tokenServerUrl] 예: http://192.168.10.20:3000/token
  static Future<ConnectionDetails> fetchFromServer({
    required String tokenServerUrl,
    required String roomName,
    required String participantName,
    required String identity,
    String? pin,
  }) async {
    final params = {
      'room': roomName,
      'name': participantName,
      'identity': identity,
    };
    if (pin != null && pin.isNotEmpty) params['pin'] = pin;
    final uri = Uri.parse(tokenServerUrl).replace(queryParameters: params);

    final http.Response resp;
    try {
      resp = await http.get(uri);
    } catch (e) {
      throw Exception('토큰 서버에 연결할 수 없습니다: $tokenServerUrl\n서버 실행/주소를 확인하세요.\n$e');
    }

    if (resp.statusCode != 200) {
      throw Exception('토큰 발급 실패 (HTTP ${resp.statusCode}).\n${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = data['serverUrl'] as String?;
    final token = (data['participantToken'] ?? data['token']) as String?;
    if (url == null || token == null) {
      throw Exception('응답에 serverUrl/participantToken 이 없습니다: ${resp.body}');
    }
    return ConnectionDetails(serverUrl: url, token: token);
  }

  /// 수동 입력 방식(서버 URL + 토큰 직접 붙여넣기).
  static ConnectionDetails manual({
    required String serverUrl,
    required String token,
  }) {
    return ConnectionDetails(serverUrl: serverUrl.trim(), token: token.trim());
  }
}
