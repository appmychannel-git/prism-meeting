import 'dart:async';

import 'package:app_links/app_links.dart';
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
import 'share_qr.dart';

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

  // CCTV 전용 모드에서 홈이 이 화면이라, 들어오는 CCTV 딥링크(?cctv=)를 여기서 처리.
  AppLinks? _appLinks;
  StreamSubscription<Uri>? _linkSub;
  String? _lastLink;

  @override
  void initState() {
    super.initState();
    _load();
    if (AppConfig.cctvOnly) _initDeepLinks();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  // CCTV 전용 앱: QR(딥링크 ?cctv=<코드>)로 열리면 비번 입력 후 바로 시청.
  Future<void> _initDeepLinks() async {
    _appLinks = AppLinks();
    try {
      final initial = await _appLinks!.getInitialLink();
      if (initial != null) _onLink(initial);
    } catch (_) {}
    _linkSub = _appLinks!.uriLinkStream.listen(_onLink);
  }

  void _onLink(Uri uri) {
    final code = uri.queryParameters['cctv'];
    if (code == null || code.trim().isEmpty) return;
    final key = uri.toString();
    if (key == _lastLink) return; // 중복 처리 방지
    _lastLink = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openByCode(code.trim());
    });
  }

  // 딥링크 코드로 시청: 비번 입력 → 목록 저장(다음부터 원터치) → 시청.
  Future<void> _openByCode(String code) async {
    final pin = await _promptPin();
    if (pin == null || pin.trim().isEmpty || !mounted) return;
    final e = CctvEntry(code: code, pin: pin.trim(), name: code);
    await CctvStore.add(e);
    await _load();
    if (!mounted) return;
    _open(e);
  }

  Future<String?> _promptPin() async {
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('cctv_enter_pin')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          obscureText: true,
          decoration: InputDecoration(
            hintText: L.t('cctv_password'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(L.t('ok'))),
        ],
      ),
    );
    ctrl.dispose();
    return pin;
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
    _codeCtrl.text = _extractCctvCode(raw);
    setState(() {});
  }

  /// 스캔값에서 CCTV 코드만 뽑아낸다.
  /// - 딥링크 URL(`.../apps/meeting/<brand>/?cctv=<코드>`) → cctv 쿼리값
  /// - 레거시 방 이름(`cctv-<코드>`) → 접두어 제거
  /// - 그 외 → 그대로(순수 코드)
  String _extractCctvCode(String raw) {
    var v = raw.trim();
    try {
      final u = Uri.parse(v);
      final c = u.queryParameters['cctv'];
      if (c != null && c.trim().isNotEmpty) return c.trim();
    } catch (_) {}
    if (v.startsWith('cctv-')) v = v.substring(5);
    return v;
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
          // CCTV 전용 모드(홈)에선 회의쪽 드로어가 없으므로, 앱 언어·앱 공유를 여기서 제공.
          actions: [
            if (AppConfig.cctvOnly)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'lang') {
                    showAppLanguagePicker(context);
                  } else if (v == 'share') {
                    showShareLinkQrDialog(
                      context,
                      title: L.t('share_app_title'),
                      message: L.t('share_app_msg', {'app': AppConfig.appBrand}),
                      targetUrl: AppConfig.apkUrl,
                    );
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'lang', child: Text(L.t('app_language'))),
                  PopupMenuItem(
                      value: 'share', child: Text(L.t('menu_share_app'))),
                ],
              ),
          ],
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
