import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 통화 종류.
class CallType {
  static const outgoing = 'outgoing'; // 내가 건 전화
  static const incoming = 'incoming'; // 받은 전화
  static const missed = 'missed'; // 부재중
}

/// 통화 기록 한 건.
class CallLogEntry {
  final String peerUuid;
  final String peerName;
  final String type;
  final bool video;
  final int ts; // millisecondsSinceEpoch

  const CallLogEntry({
    required this.peerUuid,
    required this.peerName,
    required this.type,
    required this.video,
    required this.ts,
  });

  Map<String, dynamic> toJson() => {
        'uuid': peerUuid,
        'name': peerName,
        'type': type,
        'video': video,
        'ts': ts,
      };

  factory CallLogEntry.fromJson(Map<String, dynamic> j) => CallLogEntry(
        peerUuid: (j['uuid'] ?? '').toString(),
        peerName: (j['name'] ?? '').toString(),
        type: (j['type'] ?? '').toString(),
        video: j['video'] == true,
        ts: (j['ts'] is int) ? j['ts'] as int : int.tryParse('${j['ts']}') ?? 0,
      );
}

/// 통화 기록 로컬 저장(최근 100건).
class CallLog {
  static const _key = 'call_log';
  static const _max = 100;

  static Future<List<CallLogEntry>> list() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) => CallLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 최근 것이 앞에 오도록 추가.
  static Future<void> add(CallLogEntry e) async {
    final list = await CallLog.list();
    list.insert(0, e);
    if (list.length > _max) list.removeRange(_max, list.length);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(list.map((x) => x.toJson()).toList()));
  }

  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key);
  }
}
