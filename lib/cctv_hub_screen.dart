import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
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
import 'supported_devices.dart';

/// CCTV 허브 — 내 CCTV(저장) 시청 / 새 CCTV 추가 / 이 기기 공유.
class CctvHubScreen extends StatefulWidget {
  const CctvHubScreen({super.key});
  @override
  State<CctvHubScreen> createState() => _CctvHubScreenState();
}

class _CctvHubScreenState extends State<CctvHubScreen>
    with SingleTickerProviderStateMixin {
  final _noteCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  List<CctvEntry> _saved = [];
  bool _isCamera = false;
  bool _showAddForm = false; // 시청 탭: 저장 목록이 있을 때 "새 CCTV 추가" 폼 표시 여부
  // QR목록(송출 코드 그룹) + 이 기기 고정 코드.
  List<CctvShareGroup> _groups = [];
  String _myCode = '';
  String _myName = ''; // 이 기기 이름(QR에 담아 시청자 목록에 표시)
  // 친구목록 탭: 이 기기 CCTV를 추가한 시청자들(호스트용).
  List<CctvViewer> _viewers = [];
  bool _viewersLoading = false;

  static const int _friendsTabIndex = 2; // 시청/녹화/친구목록/QR목록
  late final TabController _tabs;

  // CCTV 전용 모드에서 홈이 이 화면이라, 들어오는 CCTV 딥링크(?cctv=)를 여기서 처리.
  AppLinks? _appLinks;
  StreamSubscription<Uri>? _linkSub;
  String? _lastLink;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    // 친구목록 탭으로 전환할 때마다 시청자 목록을 새로고침.
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && _tabs.index == _friendsTabIndex) {
        _loadViewers();
      }
    });
    _load().then((_) async {
      // 이름·비번을 디렉터리에 1회 게시(기존 사용자·코드 추가 시 이름 조회 +
      // 원격 깨우기 비번 대조 보장).
      if (mounted && _myName.isNotEmpty) {
        final pins = await CctvStore.enabledSharePins();
        DirectoryService.updateCctvPins(_myCode, pins, name: _myName);
      }
      _loadViewers(); // 친구목록(시청자) 조회
      _refreshEntryNames(); // 추가해둔 CCTV들의 기기 이름을 최신으로 갱신
    });
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
    _tabs.dispose();
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
    // 웹: app_links 가 쿼리(?cctv=&pin=)를 못 넘기는 경우 대비해 현재 URL 에서도 읽는다
    // (같은 URL 이면 _lastLink 로 중복 무시).
    if (kIsWeb) _onLink(Uri.base);
    _linkSub = _appLinks!.uriLinkStream.listen(_onLink);
  }

  void _onLink(Uri uri) {
    final code = uri.queryParameters['cctv'];
    if (code == null || code.trim().isEmpty) return;
    final pin = uri.queryParameters['pin']; // 그룹별 QR은 비번도 함께 담김
    final name = uri.queryParameters['nm']; // 송출 기기 이름(목록 표시용)
    final key = uri.toString();
    if (key == _lastLink) return; // 중복 처리 방지
    _lastLink = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openByCode(code.trim(), pin: pin?.trim(), name: name?.trim());
    });
  }

  // 딥링크 코드로 시청: 비번(QR에 담겼으면 그대로, 없으면 입력) → 목록 저장 → 시청.
  // [name]은 QR에 담긴 송출 기기 이름(없으면 서버에서 조회, 그래도 없으면 코드).
  Future<void> _openByCode(String code, {String? pin, String? name}) async {
    var p = pin;
    final hadPin = p != null && p.isNotEmpty;
    if (!hadPin) {
      p = await _promptPin();
    }
    if (p == null || p.trim().isEmpty || !mounted) return;
    // 기기 이름: QR에 있으면 사용, 없으면 등록된 기기명 조회, 그래도 없으면 코드.
    var nm = (name ?? '').trim();
    if (nm.isEmpty) nm = await DirectoryService.getCctvCameraName(code);
    if (nm.isEmpty) nm = code;
    final e = CctvEntry(code: code, pin: p.trim(), name: nm);
    await CctvStore.add(e);
    await _load();
    if (!mounted) return;
    _open(e, askPin: false); // 방금 비번을 받았으므로 바로 재생
  }

  Future<String?> _promptPin({String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
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
    final name = await DeviceId.name();
    if (!mounted) return;
    setState(() {
      _saved = s;
      _isCamera = cam;
      _groups = groups;
      _myCode = code;
      _myName = name;
    });
  }

  /// 추가해둔 CCTV들의 기기 이름을 서버에서 다시 받아 최신으로 갱신(호스트가 이름을
  /// 바꾼 경우 반영). 변경된 게 있으면 목록을 다시 그린다.
  Future<void> _refreshEntryNames() async {
    if (_saved.isEmpty) return;
    var changed = false;
    for (final e in List<CctvEntry>.from(_saved)) {
      final nm = await DirectoryService.getCctvCameraName(e.code);
      if (nm.isNotEmpty && nm != e.name) {
        await CctvStore.add(e.copyWith(name: nm));
        changed = true;
      }
    }
    if (changed && mounted) await _load();
  }

  /// 이 기기 CCTV를 추가한 시청자 목록(친구목록 탭) 조회.
  Future<void> _loadViewers() async {
    if (_myCode.isEmpty) return;
    if (mounted) setState(() => _viewersLoading = true);
    final vs = await DirectoryService.listCctvViewers(_myCode);
    if (!mounted) return;
    setState(() {
      _viewers = vs;
      _viewersLoading = false;
    });
  }

  // 친구목록 탭: 이 기기 CCTV를 추가한 사람들 + 차단/해제.
  Widget _friendsTab() {
    return RefreshIndicator(
      onRefresh: _loadViewers,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(L.t('cctv_viewers_title'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.white70)),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: L.t('retry'),
                onPressed: _viewersLoading ? null : _loadViewers,
              ),
            ],
          ),
          Text(L.t('cctv_viewers_sub'),
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 12),
          if (_viewersLoading && _viewers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_viewers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(L.t('cctv_viewers_empty'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54)),
            )
          else
            for (final v in _viewers) _viewerTile(v),
        ],
      ),
    );
  }

  Widget _viewerTile(CctvViewer v) {
    final label = v.name.isNotEmpty ? v.name : v.uuid;
    final tile = Card(
      child: ListTile(
        leading: Icon(Icons.person,
            color: v.blocked ? Colors.white30 : const Color(0xFF4ADE80)),
        title: Text(label),
        subtitle: v.blocked
            ? Text(L.t('cctv_viewer_blocked'),
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF8A80)))
            : (v.lastSeen.isNotEmpty
                ? Text(v.lastSeen, style: const TextStyle(fontSize: 11))
                : null),
        trailing: TextButton.icon(
          onPressed: () => _toggleBlockViewer(v),
          icon: Icon(v.blocked ? Icons.check_circle_outline : Icons.block,
              size: 18),
          label: Text(v.blocked ? L.t('unblock') : L.t('block')),
        ),
      ),
    );
    return v.blocked ? Opacity(opacity: 0.6, child: tile) : tile;
  }

  Future<void> _toggleBlockViewer(CctvViewer v) async {
    final toBlock = !v.blocked;
    final label = v.name.isNotEmpty ? v.name : v.uuid;
    if (toBlock &&
        !await confirmDialog(
            context, L.t('cctv_block_confirm', {'name': label}),
            confirmLabel: L.t('block'))) {
      return;
    }
    final ok =
        await DirectoryService.setCctvViewerBlocked(_myCode, v.uuid, toBlock);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t('cctv_block_failed'))));
      return;
    }
    await _loadViewers();
  }

  /// 그룹(토글/추가/삭제/비번) 변경을 서버 방 메타데이터에 즉시 반영.
  /// 송출 중이거나 방이 잔존하는 동안에도 새 시청자부터 바로 적용된다.
  /// (방이 없으면 서버가 무시 → 다음 송출 때 카메라가 어차피 재지정)
  Future<void> _syncPins() async {
    final pins = await CctvStore.enabledSharePins();
    await DirectoryService.updateCctvPins(_myCode, pins, name: _myName);
  }

  /// "이 기기를 CCTV로 공유" — 기본 비밀번호를 확인한 뒤에만 송출 시작.
  /// (아무나 송출을 켜지 못하도록. 기본 그룹이 아직 없으면 송출 화면에서 첫 코드 설정 유도.)
  Future<void> _startShare() async {
    final groups = await CctvStore.shareGroups();
    if (!mounted) return;
    if (groups.isNotEmpty) {
      final basePin = groups.first.pin;
      final p = await _promptPin();
      if (p == null || !mounted) return;
      if (p.trim() != basePin) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t('cctv_pw_wrong'))));
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CctvShareScreen()),
    );
    await _load();
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

  /// CCTV 시청 시작. [askPin]이면 비밀번호 입력창을 띄워(저장값 미리 채움) 확인 후 재생
  /// (틀리면 접속 단계에서 바로 안내됨). QR/수동추가처럼 방금 비번을 받은 경우엔 false.
  Future<void> _open(CctvEntry e, {bool askPin = true}) async {
    var entry = e;
    if (askPin) {
      // 저장된 비번은 채우지 않고 매번 새로 입력받는다(빈 칸).
      final p = await _promptPin();
      if (p == null || p.trim().isEmpty || !mounted) return;
      final pin = p.trim();
      if (pin != e.pin) {
        // 입력한 새 비번을 저장(다음부터 이 값으로 채움).
        entry = e.copyWith(pin: pin);
        await CctvStore.add(entry);
        await _load();
      }
    }
    // 호스트의 "친구목록"에 이 기기를 시청자로 등록하고, 원격으로 깨운다.
    // 깨우기엔 비번·기기ID를 함께 보내 서버가 차단/비번을 먼저 검사(틀리면 안 깨움).
    final myUuid = await DeviceId.uuid();
    if (!mounted) return;
    DirectoryService.registerCctvViewer(entry.code, myUuid, _myName);
    DirectoryService.requestCctvWake(entry.code,
        pin: entry.pin, uuid: myUuid);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CctvViewScreen(roomId: entry.roomId, pin: entry.pin),
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
    final note = _noteCtrl.text.trim();
    // 기기 이름: 등록된 기기명 조회(없으면 코드). 목록 제목에 사용.
    var nm = await DirectoryService.getCctvCameraName(code);
    if (nm.isEmpty) nm = code;
    final e = CctvEntry(code: code, pin: pin, name: nm, note: note);
    await CctvStore.add(e); // 저장 → 다음부턴 목록에서 원터치
    _noteCtrl.clear();
    _codeCtrl.clear();
    _pinCtrl.clear();
    _showAddForm = false; // 추가 후엔 목록+버튼 상태로 복귀
    await _load();
    if (!mounted) return;
    _open(e, askPin: false); // 방금 비번을 입력했으므로 바로 재생
  }

  /// 저장된 CCTV 편집 — 이름·코드는 보기 전용, 메모·비밀번호는 변경 가능.
  Future<void> _editEntry(CctvEntry e) async {
    final noteCtrl = TextEditingController(text: e.note);
    final pinCtrl = TextEditingController(text: e.pin);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(e.name.isNotEmpty ? e.name : e.code),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 이름·코드(보기 전용).
            Text('${L.t('cctv_setup_name')}: ${e.name.isNotEmpty ? e.name : '-'}',
                style: const TextStyle(fontSize: 13, color: Colors.white70)),
            const SizedBox(height: 4),
            Text('${L.t('cctv_code')}: ${e.code}',
                style: const TextStyle(fontSize: 13, color: Colors.white70)),
            const SizedBox(height: 12),
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

  // 좌측 햄버거 드로어(CCTV 전용 모드): 앱 언어 · 앱 공유.
  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(L.t('app_language')),
              onTap: () {
                Navigator.pop(context);
                showAppLanguagePicker(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(L.t('menu_share_app')),
              onTap: () {
                Navigator.pop(context);
                showShareLinkQrDialog(
                  context,
                  title: L.t('share_app_title'),
                  message: L.t('share_app_msg', {'app': AppConfig.appBrand}),
                  targetUrl: AppConfig.apkUrl,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // CCTV 전용 모드(홈)에선 좌측 햄버거 드로어로 앱 언어·앱 공유 제공(미팅과 통일).
      drawer: AppConfig.cctvOnly ? _buildDrawer(context) : null,
      appBar: AppBar(
        centerTitle: true,
        title: Text(L.t('menu_cctv')),
        // 우측 상단: 앱 버전(5번 누르면 지원 기기 안내).
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 14),
            child: Center(child: VersionBadge()),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.center,
          tabs: [
            Tab(icon: const Icon(Icons.play_circle_outline),
                text: L.t('cctv_tab_view')),
            Tab(icon: const Icon(Icons.videocam),
                text: L.t('cctv_tab_share')),
            Tab(icon: const Icon(Icons.people_outline),
                text: L.t('cctv_tab_friends')),
            Tab(icon: const Icon(Icons.qr_code_2),
                text: L.t('cctv_tab_qrlist')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _viewTab(),
          _shareTab(),
          _friendsTab(),
          _qrListTab(),
        ],
      ),
    );
  }

  // 시청 탭:
  //  - 저장된 CCTV가 없으면: 새 CCTV 추가 입력폼
  //  - 있으면: 내 CCTV 목록만. 아래 "새 CCTV 추가" 버튼 → 누르면 입력폼이 열린다.
  Widget _viewTab() {
    final showForm = _saved.isEmpty || _showAddForm;
    return ListView(
      // 하단: 시스템 네비게이션바가 노출된 기기에서 버튼이 가리지 않도록 여백 추가.
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewPadding.bottom + 32),
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
                // 제목=기기 이름(없으면 코드), 부제=메모(있을 때만).
                title: Text(e.name.isNotEmpty ? e.name : e.code),
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
          const SizedBox(height: 16),
        ],
        if (!showForm)
          // 목록만 보여주고, 추가는 버튼을 눌러 폼을 연다.
          OutlinedButton.icon(
            onPressed: () => setState(() => _showAddForm = true),
            icon: const Icon(Icons.add),
            label: Text(L.t('cctv_add')),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(L.t('cctv_add'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.white70)),
              ),
              // 목록이 있을 때만: 폼 닫기(취소).
              if (_saved.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _showAddForm = false),
                  child: Text(L.t('cancel')),
                ),
            ],
          ),
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
            leading: const Icon(Icons.videocam, size: 30),
            title: Text(L.t('cctv_share')),
            subtitle: Text(L.t('cctv_share_desc')),
            onTap: _startShare,
          ),
        ),
        const SizedBox(height: 8),
        // 송출 유지 조건 안내(백그라운드로 가면 멈춤).
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1F27),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 18, color: Colors.white54),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  L.t('cctv_share_fg_notice'),
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
            ],
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
        // 기기 이름(QR 공유 시 상대 목록에 표시) — 여기서 확인·수정.
        Card(
          child: ListTile(
            leading: const Icon(Icons.badge_outlined, size: 28),
            title: Text('${L.t('cctv_setup_name')}: '
                '${_myName.isNotEmpty ? _myName : '-'}'),
            subtitle: Text(L.t('cctv_name_sub'),
                style: const TextStyle(fontSize: 12)),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: L.t('cctv_edit'),
              onPressed: _editMyName,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.videocam, size: 28),
            title: Text('${L.t('cctv_my_code')}: $_myCode'),
            subtitle: Text(L.t('cctv_qrlist_hint'),
                style: const TextStyle(fontSize: 12)),
            // 내 코드 영역 오른쪽: 코드 재발급(새 코드로 교체, 그룹 유지).
            trailing: TextButton.icon(
              onPressed: _reissueCode,
              icon: const Icon(Icons.autorenew, size: 18),
              label: Text(L.t('cctv_reissue')),
            ),
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
    // 첫(기본) 코드는 비활성·삭제 불가(항상 최소 1개 활성 유지).
    final isDefault = _groups.isNotEmpty && _groups.first.id == g.id;
    final active = isDefault || g.enabled;
    final tile = Card(
      child: ListTile(
        leading: Icon(Icons.vpn_key,
            color: active ? const Color(0xFF4ADE80) : Colors.white30),
        // 이름만 표시(비번은 QR 보기·편집에서 확인).
        title: Text(g.name),
        subtitle: isDefault
            ? Text(L.t('cctv_default_badge'),
                style: const TextStyle(fontSize: 11, color: Colors.white38))
            : null,
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
              value: active,
              // 기본 코드는 토글 비활성(항상 켜짐).
              onChanged: isDefault
                  ? null
                  : (v) async {
                      await CctvStore.updateShareGroup(g.id, enabled: v);
                      await _load();
                      await _syncPins(); // 서버에 즉시 반영
                    },
            ),
            // 기본 코드는 삭제 버튼 숨김(자리 맞춤용 빈 공간).
            if (!isDefault)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteCode(g),
              )
            else
              const SizedBox(width: 48),
          ],
        ),
      ),
    );
    return active ? tile : Opacity(opacity: 0.55, child: tile);
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
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: L.t('cctv_password'),
                hintText: L.t('cctv_pw_hint6'),
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
    if (saved != true) return;
    // 비밀번호는 숫자 6자리 고정.
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t('cctv_pw_6digit'))));
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
    await _syncPins(); // 비번 변경/추가를 서버에 즉시 반영
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
    await _syncPins(); // 삭제를 서버에 즉시 반영(그 비번으로 새 접속 차단)
  }

  // 기기 이름 수정 — 저장 + 디렉터리 게시(새 QR/시청자 목록에 반영).
  Future<void> _editMyName() async {
    final ctrl = TextEditingController(text: _myName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(L.t('cctv_setup_name')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          decoration: InputDecoration(
            hintText: L.t('cctv_setup_name_hint'),
            border: const OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
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
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty) return;
    await DeviceId.setName(name);
    await DirectoryService.setCctvName(_myCode, name);
    await _load();
  }

  // 코드 재발급: 새 코드로 교체(그룹/비번 유지 → QR만 새 코드로). 기존 QR은 전부 무효.
  Future<void> _reissueCode() async {
    if (!await confirmDialog(context, L.t('cctv_reissue_confirm'),
        confirmLabel: L.t('cctv_reissue'))) {
      return;
    }
    final oldCode = _myCode;
    final newCode = await CctvStore.reissueMyCode();
    // 대기 중 원격 켜기 등록 상태면 새 코드로 재등록(옛 코드 해제).
    if (_isCamera) {
      try {
        final uuid = await DeviceId.uuid();
        final name = await DeviceId.name();
        await DirectoryService.unregisterCctvCamera(oldCode);
        await DirectoryService.registerCctvCamera(
            code: newCode, uuid: uuid, name: name.isNotEmpty ? name : 'CCTV');
      } catch (_) {}
    }
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t('cctv_reissue_done'))));
    }
  }

  // 그룹 QR(코드+비번 내장) 보기. 하단 바에 가리지 않도록 스크롤 + 넉넉한 하단 여백.
  void _showGroupQr(CctvShareGroup g) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E1116),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        child: Padding(
          // 하단 시스템바/네비게이션바 높이 + 여유를 더해 내용이 가리지 않게 한다.
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, MediaQuery.of(ctx).viewPadding.bottom + 56),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 기기 이름(QR에 담겨 상대 목록에 표시됨).
              if (_myName.isNotEmpty) ...[
                Text(_myName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
              ],
              Text(g.name,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SizedBox(
                  width: 170,
                  height: 170,
                  child: PrettyQrView.data(
                    data: AppConfig.cctvLink(_myCode, pin: g.pin, name: _myName),
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
