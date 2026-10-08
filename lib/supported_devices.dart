import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'l10n.dart';

/// 기능이 검증된("지원") 기기 목록 + 현재 기기 지원 여부 안내.
///
/// 새 기기에 설치하면 카메라 등 일부 기능이 동작하지 않을 수 있어, 우리가 실제로
/// 확인한 기기만 "지원 기기"로 표시한다. 새 기기를 검증하면 [list]에 추가하면 된다.
class SupportedDevices {
  SupportedDevices._();

  static const MethodChannel _ch = MethodChannel('app/fullscreen');

  /// 인증 기기 목록은 전적으로 서버 API 로 관리한다(하드코딩 없음).
  /// API 를 못 받으면 목록이 비어 아무 기기도 "인증"으로 표시되지 않는다.
  static const List<Map<String, String>> _fallback = [];

  static List<Map<String, String>>? _fetched; // 서버에서 받아온 목록(성공 시)
  static String _man = '';
  static String _mod = '';
  static bool _loaded = false;

  /// 현재 적용 목록 = 서버 목록(성공 시) 아니면 하드코딩 fallback.
  static List<Map<String, String>> get list => _fetched ?? _fallback;

  static Future<void> _ensure() async {
    if (_loaded) return;
    _loaded = true;
    // 1) 기기 정보(manufacturer/model)
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final info = await _ch.invokeMethod<dynamic>('getDeviceInfo');
        if (info is Map) {
          _man = ((info['manufacturer'] as String?) ?? '').trim();
          _mod = ((info['model'] as String?) ?? '').trim();
        }
      } catch (_) {}
    }
    // 2) 인증 기기 목록 JSON(서버 정적 파일). 실패/빈 목록이면 하드코딩 fallback 유지.
    try {
      final uri = Uri.parse(AppConfig.certifiedDevicesUrl);
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        final arr = (j is Map ? j['devices'] : j) as List?;
        if (arr != null && arr.isNotEmpty) {
          _fetched = arr
              .map<Map<String, String>>((e) => {
                    'manufacturer': (e['manufacturer'] ?? '').toString(),
                    'model': (e['model'] ?? '').toString(),
                    'label': (e['label'] ?? '').toString(),
                  })
              .toList();
        }
      }
    } catch (_) {}
  }

  // 인증 여부는 model(기기명) 기준으로만 판정한다(manufacturer 표기 차이로 인한
  // 오탐 방지; manufacturer/label 은 표시용).
  static bool _isMatch(String man, String mod) {
    if (mod.isEmpty) return false;
    final m = mod.toLowerCase();
    return list.any((d) => (d['model'] ?? '').toLowerCase() == m);
  }

  /// 현재 기기 정보 + 지원 여부.
  static Future<({String manufacturer, String model, bool supported})>
      current() async {
    await _ensure();
    return (manufacturer: _man, model: _mod, supported: _isMatch(_man, _mod));
  }
}

/// 버전 텍스트를 5번 누르면 지원 기기 안내창을 띄우는 배지.
class VersionBadge extends StatefulWidget {
  const VersionBadge({super.key, this.fontSize = 12, this.color});

  final double fontSize;
  final Color? color;

  @override
  State<VersionBadge> createState() => _VersionBadgeState();
}

class _VersionBadgeState extends State<VersionBadge> {
  int _taps = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  void _onTap() {
    final now = DateTime.now();
    if (now.difference(_last) > const Duration(seconds: 2)) _taps = 0;
    _last = now;
    _taps++;
    if (_taps >= 5) {
      _taps = 0;
      showSupportedDeviceDialog(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: Text(
        'v${AppConfig.appVersion}',
        style: TextStyle(
          fontSize: widget.fontSize,
          color: widget.color ?? Colors.white.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}

/// 현재 기기 지원 여부 안내창(버전 5탭).
Future<void> showSupportedDeviceDialog(BuildContext context) async {
  final d = await SupportedDevices.current();
  if (!context.mounted) return;
  final dev = '${d.manufacturer} ${d.model}'.trim();
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(L.t('dev_support_title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${L.t('dev_this')}: ${dev.isEmpty ? '-' : dev}',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(d.supported ? Icons.check_circle : Icons.error_outline,
                  color: d.supported
                      ? const Color(0xFF4ADE80)
                      : const Color(0xFFF59E0B)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d.supported ? L.t('dev_supported') : L.t('dev_unverified'),
                  style: TextStyle(
                    color: d.supported
                        ? const Color(0xFF4ADE80)
                        : const Color(0xFFF59E0B),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (!d.supported) ...[
            const SizedBox(height: 8),
            Text(L.t('dev_unverified_sub'),
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            showSupportedDeviceListDialog(context);
          },
          child: Text(L.t('dev_list_btn')),
        ),
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: Text(L.t('close'))),
      ],
    ),
  );
}

/// 지원 기기 목록 보기.
Future<void> showSupportedDeviceListDialog(BuildContext context) async {
  final d = await SupportedDevices.current();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(L.t('dev_list_title')),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in SupportedDevices.list)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle,
                    color: Color(0xFF4ADE80), size: 20),
                title: Text(e['label'] ?? e['model'] ?? ''),
                subtitle: Text('${e['manufacturer']} ${e['model']}',
                    style: const TextStyle(fontSize: 11)),
                trailing: (d.model.toLowerCase() ==
                        (e['model'] ?? '').toLowerCase())
                    ? Text(L.t('dev_this_badge'),
                        style: const TextStyle(
                            color: Color(0xFF4ADE80), fontSize: 11))
                    : null,
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: Text(L.t('close'))),
      ],
    ),
  );
}
