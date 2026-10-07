import 'dart:async';

import 'package:flutter/material.dart';

import 'block_store.dart';
import 'call.dart';
import 'confirm_dialog.dart';
import 'device_id.dart';
import 'directory.dart';
import 'friends.dart';
import 'l10n.dart';
import 'scan_screen.dart';

/// 친구 목록 화면.
///  - 친구 선택 → 음성/영상 전화
///  - QR 스캔 / 코드 입력 → 친구추가
///  - 친구 추천: 나를 친구추가한 사람(서버 기록)을 보여주고 맞추가 가능
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with WidgetsBindingObserver {
  List<Friend> _friends = [];
  List<Friend> _suggestions = []; // 나를 추가했지만 내가 아직 안 추가한 사람
  // 차단 상태(uuid 집합) + 친구목록엔 없지만 차단된 사람(과거 차단 — 목록에 함께 표시).
  Set<String> _blockedUuids = {};
  List<Friend> _blockedOnly = [];
  // 차단 내역을 함께 볼지(우측 상단 체크박스). 기본 = 함께 보기.
  bool _showBlocked = true;
  final Map<String, DeviceStatus> _status = {}; // uuid → 온라인/통화중/이름
  String _myUuid = '';
  String _myName = '';
  bool _loading = true;
  // 친구 온라인/통화중 상태를 주기적으로 다시 조회(화면을 열어둔 채로도 색이 갱신).
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // 20초마다 상태 재조회 → 친구가 켜지면/통화 시작하면 색이 바뀐다.
    _statusTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_friends.isNotEmpty) _loadStatuses(_friends);
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱으로 돌아오면 즉시 최신 상태로 갱신.
    if (state == AppLifecycleState.resumed && _friends.isNotEmpty) {
      _loadStatuses(_friends);
    }
  }

  Future<void> _load() async {
    final id = await DeviceId.uuid();
    final nm = await DeviceId.name();
    // 재설치 후 로컬이 비었으면 서버(내가 추가한 친구)에서 복구·병합.
    try {
      await FriendStore.mergeAll(await DirectoryService.myFriends(id));
    } catch (_) {}
    final fs = await FriendStore.list();
    // 나를 추가한 사람들 중, 내가 아직 친구로 안 넣은 사람만 추천으로(차단 제외).
    final added = await DirectoryService.whoAddedMe(id);
    final friendIds = fs.map((f) => f.uuid).toSet();
    final blockedList = await BlockStore.list();
    final blocked = blockedList.map((f) => f.uuid).toSet();
    final sugg = added
        .where((f) =>
            f.uuid != id &&
            !friendIds.contains(f.uuid) &&
            !blocked.contains(f.uuid))
        .toList();
    // 친구목록엔 없지만 차단된 사람(과거 차단)도 목록에 함께 표시.
    final blockedOnly =
        blockedList.where((f) => !friendIds.contains(f.uuid)).toList();
    if (!mounted) return;
    setState(() {
      _friends = fs;
      _myUuid = id;
      _myName = nm;
      _suggestions = sugg;
      _blockedUuids = blocked;
      _blockedOnly = blockedOnly;
      _loading = false;
    });
    _loadStatuses(fs); // 온라인/통화중 + 이름 동기화(비동기, 뒤에 갱신)
  }

  /// 각 친구의 현재 상태(온라인/통화중)와 최신 이름을 조회해 갱신.
  Future<void> _loadStatuses(List<Friend> friends) async {
    var nameChanged = false;
    for (final f in friends) {
      final st = await DirectoryService.status(f.uuid);
      if (st == null) continue;
      _status[f.uuid] = st;
      // 상대가 이름을 바꿨으면 로컬 친구 이름도 갱신(자동 동기화).
      if (st.name.isNotEmpty && st.name != f.name) {
        await FriendStore.add(Friend(uuid: f.uuid, name: st.name));
        nameChanged = true;
      }
    }
    if (!mounted) return;
    if (nameChanged) {
      _friends = await FriendStore.list();
    }
    setState(() {});
  }

  /// 상태 색: 온라인=초록, 통화중=주황, 오프라인=회색.
  Color? _statusColor(String uuid) {
    final st = _status[uuid];
    if (st == null) return null;
    if (st.busy) return const Color(0xFFF59E0B);
    if (st.online) return const Color(0xFF4ADE80);
    return const Color(0xFF6B7280);
  }

  /// 친구추가(로컬 저장 + 서버에 "내가 추가함" 기록 → 상대 추천에 내가 뜸).
  Future<void> _addFriend(Friend f) async {
    if (f.uuid == _myUuid) return;
    if (!await FriendStore.isFriend(f.uuid)) {
      await FriendStore.add(f);
      await DirectoryService.addEdge(
          from: _myUuid, to: f.uuid, fromName: _myName, toName: f.name);
    }
    await _load();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (raw == null || !mounted) return;
    final f = IdPayload.parse(raw);
    if (f == null || f.uuid == _myUuid) {
      _snack(L.t('scan_invalid'));
      return;
    }
    final wasFriend = await FriendStore.isFriend(f.uuid);
    await _addFriend(f);
    if (!mounted) return;
    if (!wasFriend) _snack(L.t('friend_added'));
    _callSheet(f);
  }

  Future<void> _addByCode() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 가로 화면(TV/태블릿)에서 키보드가 뜨면 다이얼로그가 눌려 입력 글자와
        // 밑줄이 겹치던 문제 → 스크롤 가능 + 카운터 숨김 + dense 로 높이 축소.
        scrollable: true,
        title: Text(L.t('add_by_code')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 8,
          decoration: InputDecoration(
            hintText: L.t('code_hint'),
            border: const OutlineInputBorder(),
            counterText: '', // 0/8 카운터 숨김(좁을 때 밑줄과 겹침 방지)
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(L.t('ok')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (code == null || code.trim().isEmpty || !mounted) return;
    final f = await DirectoryService.lookupCode(code);
    if (!mounted) return;
    if (f == null || f.uuid == _myUuid) {
      _snack(L.t('code_not_found'));
      return;
    }
    final wasFriend = await FriendStore.isFriend(f.uuid);
    await _addFriend(f);
    if (!mounted) return;
    if (!wasFriend) _snack(L.t('friend_added'));
    _callSheet(f);
  }

  void _callSheet(Friend f) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                f.name.isNotEmpty ? f.name : L.t('unnamed'),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.call),
              title: Text(L.t('call_voice')),
              onTap: () {
                Navigator.pop(ctx);
                _call(f, video: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: Text(L.t('call_video')),
              onTap: () {
                Navigator.pop(ctx);
                _call(f, video: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _call(Friend f, {required bool video}) {
    startDmCall(
      context,
      myUuid: _myUuid,
      myName: _myName,
      friend: f,
      video: video,
    );
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// 목록에 보여줄 친구(+과거 차단자). 활성(안 차단) 먼저, 차단된 사람은 아래로.
  /// '차단 포함' 체크 해제 시 차단된 사람은 숨긴다.
  List<Friend> get _displayFriends {
    final all = [..._friends, ..._blockedOnly];
    final visible = _showBlocked
        ? all
        : all.where((f) => !_blockedUuids.contains(f.uuid)).toList();
    final active = visible.where((f) => !_blockedUuids.contains(f.uuid));
    final blocked = visible.where((f) => _blockedUuids.contains(f.uuid));
    return [...active, ...blocked];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('menu_friends')),
        actions: [
          // 우측 상단: 차단 내역 함께 보기 체크박스(기본 켜짐).
          InkWell(
            onTap: () => setState(() => _showBlocked = !_showBlocked),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    value: _showBlocked,
                    onChanged: (v) =>
                        setState(() => _showBlocked = v ?? true),
                  ),
                  Text(L.t('show_blocked'),
                      style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: _addByCode,
            icon: const Icon(Icons.dialpad),
            tooltip: L.t('add_by_code'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scan,
        icon: const Icon(Icons.qr_code_scanner),
        label: Text(L.t('scan_qr')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  if (_suggestions.isNotEmpty) ...[
                    _sectionHeader(L.t('friend_suggestions')),
                    for (final f in _suggestions) _suggestionTile(f),
                    const Divider(height: 1),
                  ],
                  if (_displayFriends.isEmpty && _suggestions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(48),
                      child: Text(
                        L.t('friends_empty'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    )
                  else ...[
                    if (_displayFriends.isNotEmpty)
                      _sectionHeader(L.t('menu_friends')),
                    for (final f in _displayFriends) _friendTile(f),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(
          text,
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white54),
        ),
      );

  Widget _suggestionTile(Friend f) {
    return ListTile(
      leading: CircleAvatar(
        child: Text((f.name.isNotEmpty ? f.name : '?')
            .characters
            .first
            .toUpperCase()),
      ),
      title: Text(f.name.isNotEmpty ? f.name : L.t('unnamed')),
      subtitle: Text(L.t('added_you'),
          style: const TextStyle(fontSize: 12, color: Colors.white54)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonal(
            onPressed: () => _addFriend(f),
            child: Text(L.t('add_friend')),
          ),
          IconButton(
            icon: const Icon(Icons.block),
            tooltip: L.t('block'),
            onPressed: () async {
              await BlockStore.add(f);
              await _load();
            },
          ),
        ],
      ),
    );
  }

  Widget _friendTile(Friend f) {
    final blocked = _blockedUuids.contains(f.uuid);
    // 차단된 사람은 온라인 점 숨김(상태 무의미).
    final dot = blocked ? null : _statusColor(f.uuid);
    final tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            child: Text((f.name.isNotEmpty ? f.name : '?')
                .characters
                .first
                .toUpperCase()),
          ),
          if (dot != null)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF0E1116), width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(f.name.isNotEmpty ? f.name : L.t('unnamed')),
      subtitle: Text(
        blocked ? L.t('blocked_label') : f.uuid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: blocked ? 12 : 11,
          color: blocked ? const Color(0xFFFF6B6B) : null,
        ),
      ),
      onTap: () => _callSheet(f),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 전화 · 영상통화 · 차단(토글) · 삭제
          _tileAction(Icons.call, L.t('call_voice'),
              () => _call(f, video: false)),
          _tileAction(Icons.videocam, L.t('call_video'),
              () => _call(f, video: true)),
          _tileAction(
            Icons.block,
            blocked ? L.t('unblock') : L.t('block'),
            () => _toggleBlock(f),
            color: blocked ? const Color(0xFFFF6B6B) : Colors.white54,
          ),
          _tileAction(Icons.delete_outline, L.t('remove_friend'),
              () => _deleteFriend(f),
              color: Colors.white54),
        ],
      ),
    );
    // 차단된 사람은 흐리게(목록엔 남기되 비활성 느낌).
    return blocked ? Opacity(opacity: 0.6, child: tile) : tile;
  }

  // 타일용 컴팩트 아이콘 버튼(한 줄에 4개가 들어가도록 작게).
  Widget _tileAction(IconData icon, String tooltip, VoidCallback onTap,
      {Color? color}) {
    return IconButton(
      icon: Icon(icon, size: 22, color: color),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: onTap,
    );
  }

  /// 차단 토글 — 친구는 목록에 그대로 두고 차단/해제만 전환(그 사람의 전화만 자동 거절).
  Future<void> _toggleBlock(Friend f) async {
    if (_blockedUuids.contains(f.uuid)) {
      await BlockStore.remove(f.uuid);
      if (mounted) _snack(L.t('unblocked_snack'));
    } else {
      await BlockStore.add(f);
      if (mounted) _snack(L.t('blocked_snack'));
    }
    await _load();
  }

  /// 친구 삭제 — 목록에서 완전 제거(차단 상태였으면 차단목록에서도 제거 + 서버 관계 제거).
  Future<void> _deleteFriend(Friend f) async {
    if (!await confirmDialog(context, L.t('confirm_remove_friend'),
        confirmLabel: L.t('remove_friend'))) {
      return;
    }
    await FriendStore.remove(f.uuid);
    await BlockStore.remove(f.uuid);
    // 서버 관계도 제거해야 복구 로직이 되살리지 않음.
    await DirectoryService.removeEdge(from: _myUuid, to: f.uuid);
    await _load();
  }
}
