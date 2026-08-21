import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'l10n.dart';

/// QR 스캔 화면. 카메라로 스캔하거나, 갤러리의 QR 이미지를 골라 인식한다.
/// 인식되면 원본 문자열(rawValue)을 pop 으로 반환한다.
///
/// 주의: 일부 스탠드TV/태블릿은 카메라가 "외장(탈착식/USB)"이라
/// mobile_scanner(CameraX)가 카메라를 열지 못하고 검은 화면이 된다.
/// 이 경우 errorBuilder 로 안내 화면을 띄우고, 카메라를 쓰지 않는
/// "갤러리에서 선택(사진 디코드)"/"코드로 추가" 로 우회하도록 유도한다.
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

  // 갤러리에서 QR 이미지를 골라 인식(카메라를 쓰지 않음 → 외장 카메라 기기에서도 동작).
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
            // 카메라를 열지 못하는 기기(외장 카메라 등)에서 검은 화면 대신 안내.
            errorBuilder: (context, error) => _CameraUnavailable(
              onGallery: _fromGallery,
              onBack: () => Navigator.of(context).maybePop(),
            ),
            onDetect: (capture) {
              final code = capture.barcodes.isNotEmpty
                  ? capture.barcodes.first.rawValue
                  : null;
              _returnCode(code);
            },
          ),
          // 하단: 검은 화면일 때를 위한 안내 + 갤러리 버튼(액션바 외에 크게 한 번 더).
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      L.t('scan_black_hint'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _fromGallery,
                  icon: const Icon(Icons.photo_library),
                  label: Text(L.t('from_gallery')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 카메라를 열 수 없는 기기(외장/탈착식 카메라 등)용 안내 화면.
class _CameraUnavailable extends StatelessWidget {
  final VoidCallback onGallery;
  final VoidCallback onBack;
  const _CameraUnavailable({required this.onGallery, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0E1116),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined,
              size: 56, color: Colors.white38),
          const SizedBox(height: 16),
          Text(
            L.t('scan_camera_unavailable'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Text(
            L.t('scan_camera_unavailable_desc'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onGallery,
            icon: const Icon(Icons.photo_library),
            label: Text(L.t('from_gallery')),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onBack,
            child: Text(L.t('cancel')),
          ),
        ],
      ),
    );
  }
}
