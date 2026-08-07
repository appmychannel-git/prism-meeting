import 'package:flutter/material.dart';

import 'block_store.dart';
import 'call.dart';
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

class _FriendsScreenState extends State<FriendsScreen> {
  List<Friend> _friends = [];
  List<Friend> _suggestions = []; // 나를 추가했지만 내가 아직 안 추가한 사람
  final Map<String, DeviceStatus> _status = {}; // uuid → 온라인/통화중/이름
  String _myUuid = '';
  String _myName = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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
    final blocked = (await BlockStore.list()).map((f) => f.uuid).toSet();
    final sugg = added
        .where((f) =>
            f.uuid != id &&
            !friendIds.contains(f.uuid) &&
            !blocked.contains(f.uuid))
        .toList();
    if (!mounted) return;
    setState(() {
      _friends = fs;
      _myUuid = id;
      _myName = nm;
      _suggestions = sugg;
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
        title: Text(L.t('add_by_code')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 8,
          decoration: InputDecoration(
            hintText: L.t('code_hint'),
            border: const OutlineInputBorder(),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('menu_friends')),
        actions: [
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
                  if (_friends.isEmpty && _suggestions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(48),
                      child: Text(
                        L.t('friends_empty'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    )
                  else ...[
                    if (_friends.isNotEmpty)
                      _sectionHeader(L.t('menu_friends')),
                    for (final f in _friends) _friendTile(f),
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
    final dot = _statusColor(f.uuid);
    return ListTile(
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
        f.uuid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () => _callSheet(f),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: L.t('call_voice'),
            onPressed: () => _call(f, video: false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: L.t('call_video'),
            onPressed: () => _call(f, video: true),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: L.t('remove_friend'),
            onPressed: () async {
              await FriendStore.remove(f.uuid);
              // 서버 관계도 제거해야 복구 로직이 되살리지 않음.
              await DirectoryService.removeEdge(from: _myUuid, to: f.uuid);
              await _load();
            },
          ),
        ],
      ),
    );
  }
}
