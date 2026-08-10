import 'package:flutter/material.dart';

import 'l10n.dart';

/// 삭제·차단 등 되돌리기 어려운 동작 전 확인 다이얼로그.
/// 확인을 누르면 true, 취소/바깥 탭이면 false.
Future<bool> confirmDialog(
  BuildContext context,
  String message, {
  String? confirmLabel,
  bool danger = true,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(L.t('cancel')),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D))
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel ?? L.t('ok')),
        ),
      ],
    ),
  );
  return r == true;
}
