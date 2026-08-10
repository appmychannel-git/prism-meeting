import 'package:flutter/material.dart';

import 'cctv_share_screen.dart';
import 'cctv_view_screen.dart';
import 'l10n.dart';
import 'scan_screen.dart';

/// CCTV 허브 — 공유(카메라) / 시청 진입.
class CctvHubScreen extends StatefulWidget {
  const CctvHubScreen({super.key});
  @override
  State<CctvHubScreen> createState() => _CctvHubScreenState();
}

class _CctvHubScreenState extends State<CctvHubScreen> {
  final _codeCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();

  @override
  void dispose() {
    _codeCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  String _roomIdFrom(String code) {
    final c = code.trim();
    return c.startsWith('cctv-') ? c : 'cctv-$c';
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (raw == null || !mounted) return;
    // QR은 방ID(cctv-...) 를 담고 있음. 코드 칸에 표시.
    _codeCtrl.text = raw.startsWith('cctv-') ? raw.substring(5) : raw;
    setState(() {});
  }

  void _view() {
    final code = _codeCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    if (code.isEmpty || pin.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t('cctv_need_code_pw'))));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CctvViewScreen(roomId: _roomIdFrom(code), pin: pin),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L.t('menu_cctv'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 공유
          Card(
            child: ListTile(
              leading: const Icon(Icons.videocam, size: 32),
              title: Text(L.t('cctv_share')),
              subtitle: Text(L.t('cctv_share_desc')),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CctvShareScreen()),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 시청
          Text(L.t('cctv_view'),
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(height: 10),
          TextField(
            controller: _codeCtrl,
            decoration: InputDecoration(
              labelText: L.t('cctv_code'),
              hintText: 'abc-def-hij',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: L.t('scan_qr'),
                onPressed: _scan,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pinCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: L.t('cctv_password'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _view,
            icon: const Icon(Icons.play_arrow),
            label: Text(L.t('cctv_start_view')),
          ),
        ],
      ),
    );
  }
}
