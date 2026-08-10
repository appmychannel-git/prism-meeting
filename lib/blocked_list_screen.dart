import 'package:flutter/material.dart';

import 'block_store.dart';
import 'friends.dart';
import 'l10n.dart';

/// 차단 목록 관리 화면 — 차단 해제.
class BlockedListScreen extends StatefulWidget {
  const BlockedListScreen({super.key});
  @override
  State<BlockedListScreen> createState() => _BlockedListScreenState();
}

class _BlockedListScreenState extends State<BlockedListScreen> {
  List<Friend> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await BlockStore.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L.t('blocked_list'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Text(L.t('blocked_empty'),
                      style: const TextStyle(color: Colors.white54)),
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final f = _items[i];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.block)),
                      title:
                          Text(f.name.isNotEmpty ? f.name : L.t('unnamed')),
                      trailing: TextButton(
                        onPressed: () async {
                          await BlockStore.remove(f.uuid);
                          await _load();
                        },
                        child: Text(L.t('unblock')),
                      ),
                    );
                  },
                ),
    );
  }
}
