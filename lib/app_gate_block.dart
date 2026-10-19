import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'supported_devices.dart' show VersionBadge;

/// 앱 전체를 막는 화면 — (1) 강제 업데이트, (2) 원격 차단(점검/중단).
/// 서버(app-policy.asp)가 명시적으로 지시할 때만 표시된다(서버 무응답이면 안 막음).
/// CS 대응을 위해 하단 버전 배지(5탭 → 기기정보)는 이 화면에서도 유지한다.
class AppGateBlockScreen extends StatelessWidget {
  const AppGateBlockScreen({
    super.key,
    required this.title,
    required this.message,
    this.showUpdate = false,
    this.updateUrl = '',
  });

  /// 강제 업데이트 화면.
  factory AppGateBlockScreen.forceUpdate({String message = '', String updateUrl = ''}) =>
      AppGateBlockScreen(
        title: L.t('update_required_title'),
        message: message.isNotEmpty ? message : L.t('update_required_msg'),
        showUpdate: true,
        updateUrl: updateUrl,
      );

  /// 원격 차단(점검/중단) 화면.
  factory AppGateBlockScreen.blocked({String message = '', String updateUrl = ''}) =>
      AppGateBlockScreen(
        title: L.t('service_blocked_title'),
        message: message.isNotEmpty ? message : L.t('service_blocked_msg'),
        showUpdate: updateUrl.isNotEmpty,
        updateUrl: updateUrl,
      );

  final String title;
  final String message;
  final bool showUpdate;
  final String updateUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(showUpdate ? Icons.system_update : Icons.build_circle_outlined,
                      size: 64, color: const Color(0xFF5B8DEF)),
                  const SizedBox(height: 20),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                  const SizedBox(height: 12),
                  Text(message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 15, color: Colors.white70, height: 1.5)),
                  if (showUpdate) ...[
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => openUpdate(updateUrl),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(L.t('update_now')),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  const VersionBadge(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 업데이트 열기: updateUrl 있으면 그 주소, 없으면 자기 패키지의 스토어.
/// 안드로이드 네이티브(app/fullscreen) 채널 사용 — 웹/iOS는 무시(best-effort).
Future<void> openUpdate(String updateUrl) async {
  const ch = MethodChannel('app/fullscreen');
  try {
    if (updateUrl.isNotEmpty) {
      await ch.invokeMethod('openUrl', {'url': updateUrl});
    } else {
      await ch.invokeMethod('openStore');
    }
  } catch (_) {}
}

/// 권장 업데이트 안내(강제 아님) — 홈 진입 시 1회 다이얼로그. 건너뛰기 가능.
Future<void> showRecommendedUpdateDialog(BuildContext context,
    {String updateUrl = ''}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF12161C),
      title: Text(L.t('update_available_title')),
      content: Text(L.t('update_available_msg')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(L.t('update_later')),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            openUpdate(updateUrl);
          },
          child: Text(L.t('update_now')),
        ),
      ],
    ),
  );
}
