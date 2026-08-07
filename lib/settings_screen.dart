import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'blocked_list_screen.dart';
import 'fullscreen_perm.dart';
import 'l10n.dart';

/// 설정 화면 — 수락형 친구요청, 통화 알림(잠금화면) 설정 등.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _requireAccept = AppSettings.requireAccept;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L.t('menu_settings'))),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(L.t('require_accept')),
            subtitle: Text(L.t('require_accept_sub')),
            value: _requireAccept,
            onChanged: (v) async {
              await AppSettings.setRequireAccept(v);
              if (mounted) setState(() => _requireAccept = v);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.ring_volume),
            title: Text(L.t('fs_perm_menu')),
            subtitle: Text(L.t('fs_perm_menu_sub')),
            onTap: () => FullScreenPerm.openSettings(),
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: Text(L.t('blocked_list')),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BlockedListScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
