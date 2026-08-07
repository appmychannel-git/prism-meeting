import 'package:flutter/material.dart';

import 'call.dart';
import 'call_log.dart';
import 'device_id.dart';
import 'friends.dart';
import 'l10n.dart';

/// 통화 기록 화면 — 건 전화/받은 전화/부재중. 항목 탭 → 다시 걸기.
class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});
  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  List<CallLogEntry> _items = [];
  String _myUuid = '';
  String _myName = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await CallLog.list();
    final id = await DeviceId.uuid();
    final nm = await DeviceId.name();
    if (!mounted) return;
    setState(() {
      _items = items;
      _myUuid = id;
      _myName = nm;
      _loading = false;
    });
  }

  void _callAgain(CallLogEntry e, {required bool video}) {
    startDmCall(
      context,
      myUuid: _myUuid,
      myName: _myName,
      friend: Friend(uuid: e.peerUuid, name: e.peerName),
      video: video,
    );
  }

  (IconData, Color) _typeIcon(String type) {
    switch (type) {
      case CallType.outgoing:
        return (Icons.call_made, const Color(0xFF4ADE80));
      case CallType.missed:
        return (Icons.call_missed, const Color(0xFFFF6B6B));
      default:
        return (Icons.call_received, const Color(0xFF5B8DEF));
    }
  }

  String _when(int ts) {
    if (ts == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(d.hour)}:${two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return hm;
    }
    return '${two(d.month)}/${two(d.day)} $hm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('menu_history')),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: L.t('clear'),
              onPressed: () async {
                await CallLog.clear();
                await _load();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Text(L.t('history_empty'),
                      style: const TextStyle(color: Colors.white54)),
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = _items[i];
                    final (icon, color) = _typeIcon(e.type);
                    final name =
                        e.peerName.isNotEmpty ? e.peerName : L.t('unnamed');
                    return ListTile(
                      leading: Icon(icon, color: color),
                      title: Text(
                        name,
                        style: TextStyle(
                          color: e.type == CallType.missed
                              ? const Color(0xFFFF6B6B)
                              : null,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Icon(e.video ? Icons.videocam : Icons.call,
                              size: 13, color: Colors.white38),
                          const SizedBox(width: 4),
                          Text(_when(e.ts),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white38)),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.call),
                            tooltip: L.t('call_voice'),
                            onPressed: () => _callAgain(e, video: false),
                          ),
                          IconButton(
                            icon: const Icon(Icons.videocam),
                            tooltip: L.t('call_video'),
                            onPressed: () => _callAgain(e, video: true),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
