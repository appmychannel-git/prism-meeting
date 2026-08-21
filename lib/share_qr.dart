import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'config.dart';
import 'l10n.dart';

/// "공유 QR" 다이얼로그.
///
/// TV/태블릿은 카카오톡·문자를 직접 못 보낸다. 그래서 이 QR을 **옆에 있는 휴대폰**이
/// 찍으면 공유 페이지([AppConfig.shareBaseUrl])가 열리고, 거기서 [targetUrl]을
/// 카톡·문자로 **멀리 있는 사람에게 전송**할 수 있다(휴대폰이 링크 중계 역할).
///
/// [targetUrl] 예: 친구추가 링크 / 회의 초대 링크 / 앱(APK) 다운로드 링크.
Future<void> showShareLinkQrDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String targetUrl,
}) {
  // 공유 페이지 URL을 QR로 만든다. 휴대폰이 찍으면 그 페이지가 열린다.
  final shareUrl = AppConfig.sharePageUrl(
    title: title,
    message: message,
    targetUrl: targetUrl,
  );
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SizedBox(
              width: 220,
              height: 220,
              child: PrettyQrView.data(
                data: shareUrl,
                decoration: const PrettyQrDecoration(
                  shape: PrettyQrSmoothSymbol(color: Color(0xFF000000)),
                ),
                errorBuilder: (_, _, _) => Center(
                  child: Text(
                    L.t('qr_fail'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            L.t('share_qr_caption'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
        ],
      ),
      actions: [
        // 복사(대상 링크). 브라우저가 있는 기기에선 붙여넣어 바로 열 수 있다.
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: targetUrl));
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(content: Text(L.t('link_copied'))),
            );
          },
          child: Text(L.t('copy_link')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(L.t('close')),
        ),
      ],
    ),
  );
}
