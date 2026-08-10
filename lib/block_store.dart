import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'friends.dart';

/// 차단 목록(로컬). 차단한 사람은 친구 추천에서 숨기고, 그 사람의 전화를 자동 거절.
class BlockStore {
  static const _key = 'blocked';

  static Future<List<Friend>> list() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) => Friend.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> isBlocked(String uuid) async =>
      (await list()).any((f) => f.uuid == uuid);

  static Future<void> _save(List<Friend> fs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(fs.map((f) => f.toJson()).toList()));
  }

  static Future<void> add(Friend f) async {
    final fs = await list();
    if (fs.any((x) => x.uuid == f.uuid)) return;
    fs.add(f);
    await _save(fs);
  }

  static Future<void> remove(String uuid) async {
    final fs = await list();
    fs.removeWhere((f) => f.uuid == uuid);
    await _save(fs);
  }
}
