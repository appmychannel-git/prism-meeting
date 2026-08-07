import 'package:flutter/material.dart';

import 'call.dart';
import 'device_id.dart';
import 'friends.dart';
import 'l10n.dart';
import 'scan_screen.dart';

/// 친구 목록 화면. 친구 선택 → 음성/영상 전화. QR 스캔 → 친구추가/전화.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  List<Friend> _friends = [];
  String _myUuid = '';
  String _myName = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final fs = await FriendStore.list();
    final id = await DeviceId.uuid();
    final nm = await DeviceId.name();
    if (!mounted) return;
    setState(() {
      _friends = fs;
      _myUuid = id;
      _myName = nm;
      _loading = false;
    });
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (raw == null || !mounted) return;
    final f = IdPayload.parse(raw);
    if (f == null) {
      _snack(L.t('scan_invalid'));
      return;
    }
    if (f.uuid == _myUuid) {
      _snack(L.t('scan_invalid'));
      return;
    }
    final already = await FriendStore.isFriend(f.uuid);
    if (!already) {
      await FriendStore.add(f);
      await _load();
      if (!mounted) return;
      _snack(L.t('friend_added'));
    }
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
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
      appBar: AppBar(title: Text(L.t('menu_friends'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scan,
        icon: const Icon(Icons.qr_code_scanner),
        label: Text(L.t('scan_qr')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _friends.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      L.t('friends_empty'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _friends.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final f = _friends[i];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(
                          (f.name.isNotEmpty ? f.name : '?')
                              .characters
                              .first
                              .toUpperCase(),
                        ),
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
                  },
                ),
    );
  }
}
