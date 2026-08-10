import 'package:flutter/material.dart';

import 'cctv_share_screen.dart';
import 'cctv_store.dart';
import 'cctv_view_screen.dart';
import 'l10n.dart';
import 'scan_screen.dart';

/// CCTV 허브 — 내 CCTV(저장) 시청 / 새 CCTV 추가 / 이 기기 공유.
class CctvHubScreen extends StatefulWidget {
  const CctvHubScreen({super.key});
  @override
  State<CctvHubScreen> createState() => _CctvHubScreenState();
}

class _CctvHubScreenState extends State<CctvHubScreen> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  List<CctvEntry> _saved = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await CctvStore.list();
    if (!mounted) return;
    setState(() => _saved = s);
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (raw == null || !mounted) return;
    _codeCtrl.text = raw.startsWith('cctv-') ? raw.substring(5) : raw;
    setState(() {});
  }

  void _open(CctvEntry e) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CctvViewScreen(roomId: e.roomId, pin: e.pin),
    ));
  }

  /// 새 CCTV 추가 → 목록에 저장하고 바로 시청.
  Future<void> _addAndView() async {
    final code = _codeCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    if (code.isEmpty || pin.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t('cctv_need_code_pw'))));
      return;
    }
    final name = _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : code;
    final e = CctvEntry(code: code, pin: pin, name: name);
    await CctvStore.add(e); // 저장 → 다음부턴 목록에서 원터치
    _nameCtrl.clear();
    _codeCtrl.clear();
    _pinCtrl.clear();
    await _load();
    if (!mounted) return;
    _open(e);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L.t('menu_cctv'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 내 CCTV(저장된 것) — 원터치 시청
          if (_saved.isNotEmpty) ...[
            Text(L.t('cctv_my_list'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white70)),
            const SizedBox(height: 8),
            for (final e in _saved)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.videocam),
                  title: Text(e.name),
                  subtitle: Text(e.code,
                      style: const TextStyle(fontSize: 12)),
                  onTap: () => _open(e),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_arrow),
                        tooltip: L.t('cctv_start_view'),
                        onPressed: () => _open(e),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await CctvStore.remove(e.code);
                          await _load();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
          ],

          // 이 기기 공유
          Card(
            child: ListTile(
              leading: const Icon(Icons.cast, size: 30),
              title: Text(L.t('cctv_share')),
              subtitle: Text(L.t('cctv_share_desc')),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CctvShareScreen()),
                );
              },
            ),
          ),
          const SizedBox(height: 20),

          // 새 CCTV 추가(시청)
          Text(L.t('cctv_add'),
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(height: 10),
          TextField(
            controller: _nameCtrl,
            maxLength: 20,
            decoration: InputDecoration(
              labelText: L.t('cctv_name'),
              hintText: L.t('cctv_name_hint'),
              border: const OutlineInputBorder(),
            ),
          ),
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
            onPressed: _addAndView,
            icon: const Icon(Icons.add),
            label: Text(L.t('cctv_add_view')),
          ),
        ],
      ),
    );
  }
}
