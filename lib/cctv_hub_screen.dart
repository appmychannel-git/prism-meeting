import 'package:flutter/material.dart';

import 'cctv_share_screen.dart';
import 'cctv_store.dart';
import 'cctv_view_screen.dart';
import 'config.dart';
import 'confirm_dialog.dart';
import 'device_id.dart';
import 'directory.dart';
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
  bool _isCamera = false;

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
    final cam = await CctvStore.isCamera();
    if (!mounted) return;
    setState(() {
      _saved = s;
      _isCamera = cam;
    });
  }

  /// 이 기기를 "대기 중 원격 켜기 가능한 CCTV"로 등록/해제.
  Future<void> _toggleCamera(bool on) async {
    final (code, _) = await CctvStore.myShareCredentials();
    final uuid = await DeviceId.uuid();
    final name = await DeviceId.name();
    if (on) {
      await DirectoryService.registerCctvCamera(
          code: code, uuid: uuid, name: name.isNotEmpty ? name : 'CCTV');
    } else {
      await DirectoryService.unregisterCctvCamera(code);
    }
    await CctvStore.setIsCamera(on);
    if (mounted) setState(() => _isCamera = on);
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
    // 대기 중인 CCTV면 원격으로 깨운다(이미 켜져 있으면 무시됨).
    DirectoryService.requestCctvWake(e.code);
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(L.t('menu_cctv')),
          bottom: TabBar(
            tabs: [
              Tab(icon: const Icon(Icons.play_circle_outline),
                  text: L.t('cctv_tab_view')),
              Tab(icon: const Icon(Icons.videocam),
                  text: L.t('cctv_tab_share')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _viewTab(),
            _shareTab(),
          ],
        ),
      ),
    );
  }

  // 시청 탭: 저장한 CCTV 목록 + 새 CCTV 추가.
  Widget _viewTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                subtitle:
                    Text(e.code, style: const TextStyle(fontSize: 12)),
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
                        if (!await confirmDialog(
                            context, L.t('confirm_remove_cctv'),
                            confirmLabel: L.t('delete'))) {
                          return;
                        }
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
    );
  }

  // 송출 탭: 이 기기 공유 + 대기 중 원격 켜기.
  Widget _shareTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
        if (AppConfig.supportsDeviceFeatures)
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.power_settings_new),
              title: Text(L.t('cctv_remote_register')),
              subtitle: Text(L.t('cctv_remote_register_sub')),
              value: _isCamera,
              onChanged: _toggleCamera,
            ),
          ),
      ],
    );
  }
}
