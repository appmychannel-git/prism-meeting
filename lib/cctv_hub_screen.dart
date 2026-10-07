import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'cctv_share_screen.dart';
import 'cctv_store.dart';
import 'cctv_view_screen.dart';
import 'config.dart';
import 'confirm_dialog.dart';
import 'device_id.dart';
import 'directory.dart';
import 'fullscreen_perm.dart';
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
  final _noteCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  List<CctvEntry> _saved = [];
  bool _isCamera = false;
  // QR목록(송출 코드 그룹) + 이 기기 고정 코드.
  List<CctvShareGroup> _groups = [];
  String _myCode = '';

  // CCTV 전용 모드에서 홈이 이 화면이라, 들어오는 CCTV 딥링크(?cctv=)를 여기서 처리.
  AppLinks? _appLinks;
  StreamSubscription<Uri>? _linkSub;
  String? _lastLink;

  @override
  void initState() {
    super.initState();
    _load();
    if (AppConfig.cctvOnly) {
      _initDeepLinks();
      // Android 14+ 전체화면 인텐트 권한 안내(1회). 이 권한이 없으면 대기모드에서
      // 시청자가 재생을 눌러도 원격 켜기 알림이 화면을 깨우지 못하고 소리만 난다.
      // (미팅앱은 join_screen 에서 안내하지만 CCTV 전용 앱은 홈이 이 화면이라 여기서.)
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybePromptFullScreen());
    }
  }

  // 전체화면 알림 권한이 없으면(대기모드에서 원격 켜기가 화면을 못 깨움) 설정으로 안내.
  Future<void> _maybePromptFullScreen() async {
    if (await FullScreenPerm.canUse() || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('fs_perm_title_cctv')),
        content: Text(L.t('fs_perm_desc_cctv')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('later')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('open_settings')),
          ),
        ],
      ),
    );
    if (ok == true) FullScreenPerm.openSettings();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _noteCtrl.dispose();
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
    final pin = uri.queryParameters['pin']; // 그룹별 QR은 비번도 함께 담김
    final key = uri.toString();
    if (key == _lastLink) return; // 중복 처리 방지
    _lastLink = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openByCode(code.trim(), pin: pin?.trim());
    });
  }

  // 딥링크 코드로 시청: 비번(QR에 담겼으면 그대로, 없으면 입력) → 목록 저장 → 시청.
  Future<void> _openByCode(String code, {String? pin}) async {
    var p = pin;
    if (p == null || p.isEmpty) {
      p = await _promptPin();
    }
    if (p == null || p.trim().isEmpty || !mounted) return;
    final e = CctvEntry(code: code, pin: p.trim(), name: code);
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
        scrollable: true,
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
            counterText: '',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
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
    final groups = await CctvStore.shareGroups();
    final (code, _) = await CctvStore.myShareCredentials();
    if (!mounted) return;
    setState(() {
      _saved = s;
      _isCamera = cam;
      _groups = groups;
      _myCode = code;
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
    // 이름은 쓰지 않는다(목록엔 코드명을 표시). 메모만 받는다.
    final note = _noteCtrl.text.trim();
    final e = CctvEntry(code: code, pin: pin, name: code, note: note);
    await CctvStore.add(e); // 저장 → 다음부턴 목록에서 원터치
    _noteCtrl.clear();
    _codeCtrl.clear();
    _pinCtrl.clear();
    await _load();
    if (!mounted) return;
    _open(e);
  }

  /// 저장된 CCTV의 메모·비밀번호 편집(이름은 코드명 고정이라 편집 안 함).
  Future<void> _editEntry(CctvEntry e) async {
    final noteCtrl = TextEditingController(text: e.note);
    final pinCtrl = TextEditingController(text: e.pin);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(e.code),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: noteCtrl,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: L.t('cctv_note'),
                hintText: L.t('cctv_note_hint'),
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(height: 12),
            // 비밀번호 변경(상대가 비번을 바꿨을 때 여기서 새 비번으로 갱신).
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: InputDecoration(
                labelText: L.t('cctv_password'),
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(L.t('ok'))),
        ],
      ),
    );
    final newNote = noteCtrl.text.trim();
    final newPin = pinCtrl.text.trim();
    noteCtrl.dispose();
    pinCtrl.dispose();
    if (saved != true) return;
    await CctvStore.add(e.copyWith(
      note: newNote,
      pin: newPin.isNotEmpty ? newPin : e.pin,
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
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
              Tab(icon: const Icon(Icons.qr_code_2),
                  text: L.t('cctv_tab_qrlist')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _viewTab(),
            _shareTab(),
            _qrListTab(),
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
                // 이름 영역엔 코드명을 보여주고, 부제는 메모(있을 때만).
                title: Text(e.code),
                subtitle: e.note.isNotEmpty
                    ? Text(e.note, style: const TextStyle(fontSize: 12))
                    : null,
                onTap: () => _open(e),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: L.t('cctv_edit'),
                      onPressed: () => _editEntry(e),
                    ),
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
          controller: _noteCtrl,
          maxLength: 40,
          decoration: InputDecoration(
            labelText: L.t('cctv_note'),
            hintText: L.t('cctv_note_hint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 4),
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

  // QR목록 탭: 이 기기 코드(고정) + 그룹별 코드(비번) 관리. 그룹마다 QR 발급.
  Widget _qrListTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.videocam, size: 28),
            title: Text('${L.t('cctv_my_code')}: $_myCode'),
            subtitle: Text(L.t('cctv_qrlist_hint'),
                style: const TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: 12),
        if (_groups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(L.t('cctv_no_codes'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54)),
          )
        else
          for (final g in _groups) _groupTile(g),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _addCode,
          icon: const Icon(Icons.add),
          label: Text(L.t('cctv_add_code')),
        ),
      ],
    );
  }

  Widget _groupTile(CctvShareGroup g) {
    final tile = Card(
      child: ListTile(
        leading: Icon(Icons.vpn_key,
            color: g.enabled ? const Color(0xFF4ADE80) : Colors.white30),
        title: Text(g.name),
        subtitle: Text('${L.t('cctv_password')}: ${g.pin}',
            style: const TextStyle(fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.qr_code_2),
              tooltip: 'QR',
              onPressed: () => _showGroupQr(g),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: L.t('cctv_edit'),
              onPressed: () => _editCode(g),
            ),
            Switch(
              value: g.enabled,
              onChanged: (v) async {
                await CctvStore.updateShareGroup(g.id, enabled: v);
                await _load();
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteCode(g),
            ),
          ],
        ),
      ),
    );
    return g.enabled ? tile : Opacity(opacity: 0.55, child: tile);
  }

  // 코드(그룹) 추가/편집 공용 다이얼로그. [g] 가 있으면 편집.
  Future<void> _codeDialog({CctvShareGroup? g}) async {
    final nameCtrl = TextEditingController(text: g?.name ?? '');
    final pinCtrl = TextEditingController(text: g?.pin ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(g == null ? L.t('cctv_add_code') : L.t('cctv_edit')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              maxLength: 20,
              decoration: InputDecoration(
                labelText: L.t('cctv_code_name'),
                hintText: L.t('cctv_code_name_hint'),
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
              decoration: InputDecoration(
                labelText: L.t('cctv_password'),
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(L.t('ok'))),
        ],
      ),
    );
    final name = nameCtrl.text.trim();
    final pin = pinCtrl.text.trim();
    nameCtrl.dispose();
    pinCtrl.dispose();
    if (saved != true || pin.isEmpty) {
      if (saved == true && pin.isEmpty && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t('cctv_need_password'))));
      }
      return;
    }
    final nm = name.isNotEmpty ? name : L.t('cctv_code_default');
    if (g == null) {
      await CctvStore.addShareGroup(nm, pin);
    } else {
      await CctvStore.updateShareGroup(g.id, name: nm, pin: pin);
    }
    await _load();
  }

  Future<void> _addCode() => _codeDialog();
  Future<void> _editCode(CctvShareGroup g) => _codeDialog(g: g);

  Future<void> _deleteCode(CctvShareGroup g) async {
    if (!await confirmDialog(context, L.t('confirm_remove_code'),
        confirmLabel: L.t('delete'))) {
      return;
    }
    await CctvStore.removeShareGroup(g.id);
    await _load();
  }

  // 그룹 QR(코드+비번 내장) 보기.
  void _showGroupQr(CctvShareGroup g) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E1116),
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(g.name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SizedBox(
                  width: 180,
                  height: 180,
                  child: PrettyQrView.data(
                    data: AppConfig.cctvLink(_myCode, pin: g.pin),
                    decoration: const PrettyQrDecoration(
                      shape: PrettyQrSmoothSymbol(color: Color(0xFF000000)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('${L.t('cctv_code')}: $_myCode',
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 4),
              Text('${L.t('cctv_password')}: ${g.pin}',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(L.t('cctv_share_hint'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }
}
