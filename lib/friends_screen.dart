import 'package:flutter/material.dart';

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
    // 나를 추가한 사람들 중, 내가 아직 친구로 안 넣은 사람만 추천으로.
    final added = await DirectoryService.whoAddedMe(id);
    final friendIds = fs.map((f) => f.uuid).toSet();
    final sugg = added
        .where((f) => f.uuid != id && !friendIds.contains(f.uuid))
        .toList();
    if (!mounted) return;
    setState(() {
      _friends = fs;
      _myUuid = id;
      _myName = nm;
      _suggestions = sugg;
      _loading = false;
    });
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
      trailing: FilledButton.tonal(
        onPressed: () => _addFriend(f),
        child: Text(L.t('add_friend')),
      ),
    );
  }

  Widget _friendTile(Friend f) {
    return ListTile(
      leading: CircleAvatar(
        child: Text((f.name.isNotEmpty ? f.name : '?')
            .characters
            .first
            .toUpperCase()),
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
              await _load();
            },
          ),
        ],
      ),
    );
  }
}
