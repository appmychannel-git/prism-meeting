import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import 'cctv_store.dart';
import 'device_id.dart';
import 'directory.dart';
import 'l10n.dart';
import 'push_service.dart';

/// CCTV 전용 앱 첫 실행 화면 — 기기 이름 + 기본 공유 비밀번호를 설정한다.
/// (미팅앱의 "내 아이디 만들기"에 해당. 이름은 QR 공유 시 시청자 목록에 이 기기
///  이름으로 표시되고, 비밀번호는 이 기기를 CCTV로 공유할 때의 기본 비번이 된다.)
class CctvSetupScreen extends StatefulWidget {
  const CctvSetupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<CctvSetupScreen> createState() => _CctvSetupScreenState();
}

class _CctvSetupScreenState extends State<CctvSetupScreen> {
  final _nameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final nm = await DeviceId.name();
    if (!mounted) return;
    setState(() => _nameCtrl.text = nm);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  bool get _valid =>
      _nameCtrl.text.trim().isNotEmpty &&
      RegExp(r'^\d{6}$').hasMatch(_pinCtrl.text.trim());

  Future<void> _start() async {
    if (!_valid || _saving) return;
    setState(() => _saving = true);
    final name = _nameCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    await DeviceId.setName(name);
    // 기본 공유 그룹이 아직 없으면 생성(이후 송출 시 바로 사용).
    final groups = await CctvStore.shareGroups();
    if (groups.isEmpty) {
      await CctvStore.addShareGroup(L.t('cctv_code_default'), pin);
    }
    // 이름을 디렉터리에 게시 → 다른 기기가 코드로 추가할 때 이 이름이 보인다.
    try {
      final (code, _) = await CctvStore.myShareCredentials();
      await DirectoryService.setCctvName(code, name);
    } catch (_) {}
    // Firestore 기기 등록 이름 갱신(원격 켜기/시청자 표시용).
    try {
      PushService.instance.refreshDevice();
    } catch (_) {}
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        title: Text(L.t('cctv_setup_title')),
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _valid && !_saving ? _start : null,
              child: Text(L.t('id_setup_start')),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.videocam, size: 56, color: Colors.white38),
                  const SizedBox(height: 16),
                  Text(
                    L.t('cctv_setup_desc'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _nameCtrl,
                    maxLength: 20,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: L.t('cctv_setup_name'),
                      hintText: L.t('cctv_setup_name_hint'),
                      border: const OutlineInputBorder(),
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pinCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    obscureText: true,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: L.t('cctv_setup_pw'),
                      hintText: L.t('cctv_pw_hint6'),
                      border: const OutlineInputBorder(),
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _start(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    L.t('cctv_setup_pw_desc'),
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _valid && !_saving ? _start : null,
                    child: Text(L.t('id_setup_start')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
