import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'l10n.dart';

/// QR 스캔 화면. 카메라로 스캔하거나, 갤러리의 QR 이미지를 골라 인식한다.
/// 인식되면 원본 문자열(rawValue)을 pop 으로 반환한다.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _returnCode(String? code) {
    if (_done || code == null || code.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(code);
  }

  // 갤러리에서 QR 이미지를 골라 인식.
  Future<void> _fromGallery() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null || !mounted) return;
      final result = await _controller.analyzeImage(x.path);
      final code = (result != null && result.barcodes.isNotEmpty)
          ? result.barcodes.first.rawValue
          : null;
      if (code != null && code.isNotEmpty) {
        _returnCode(code);
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t('qr_not_found'))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t('qr_not_found'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('scan_qr')),
        actions: [
          IconButton(
            onPressed: _fromGallery,
            icon: const Icon(Icons.photo_library),
            tooltip: L.t('from_gallery'),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              final code = capture.barcodes.isNotEmpty
                  ? capture.barcodes.first.rawValue
                  : null;
              _returnCode(code);
            },
          ),
          // 하단 갤러리 버튼(액션바 외에 크게 한 번 더).
          Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: Center(
              child: FilledButton.icon(
                onPressed: _fromGallery,
                icon: const Icon(Icons.photo_library),
                label: Text(L.t('from_gallery')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
