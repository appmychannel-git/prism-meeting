import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'l10n.dart';

/// QR 스캔 화면. 인식되면 원본 문자열(rawValue)을 pop으로 반환한다.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L.t('scan_qr'))),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          final code = capture.barcodes.isNotEmpty
              ? capture.barcodes.first.rawValue
              : null;
          if (code != null && code.isNotEmpty) {
            _done = true;
            Navigator.of(context).pop(code);
          }
        },
      ),
    );
  }
}
