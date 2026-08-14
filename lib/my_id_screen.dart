import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:share_plus/share_plus.dart';

import 'device_id.dart';
import 'directory.dart';
import 'friends.dart';
import 'l10n.dart';
import 'push_service.dart';

/// 내 ID 화면. 상대가 QR 스캔 / 코드 입력 / 링크로 나를 친구추가·전화할 수 있다.
class MyIdScreen extends StatefulWidget {
  const MyIdScreen({super.key});
  @override
  State<MyIdScreen> createState() => _MyIdScreenState();
}

class _MyIdScreenState extends State<MyIdScreen> {
  final _nameCtrl = TextEditingController();
  final _nameFocus = FocusNode();
  final _scroll = ScrollController();
  String? _uuid;
  String _code = '';

  @override
  void initState() {
    super.initState();
    // 이름 입력을 마치면(포커스 해제) QR이 보이도록 맨 위로 스크롤.
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _scrollToTop();
    });
    _load();
  }

  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _load() async {
    final id = await DeviceId.uuid();
    final nm = await DeviceId.name();
    if (!mounted) return;
    setState(() {
      _uuid = id;
      _nameCtrl.text = nm;
    });
    // 짧은 코드(TV/태블릿용 수동 등록)를 생성·조회해 표시.
    final code = await DirectoryService.ensureCode(id);
    if (mounted) setState(() => _code = code);
  }

  @override
  void dispose() {
    // 편집한 이름을 기기 등록(Firestore)에도 반영 → 친구에게 새 이름으로 표시.
    PushService.instance.refreshDevice();
    _nameCtrl.dispose();
    _nameFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _link => IdPayload.encode(_uuid ?? '', _nameCtrl.text.trim());

  void _copy(String text, String toast) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(toast)));
  }

  Future<void> _shareLink() async {
    try {
      await SharePlus.instance.share(
        ShareParams(text: _link, subject: L.t('my_id_title')),
      );
    } catch (_) {
      _copy(_link, L.t('link_copied'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final uuid = _uuid;
    final hasName = _nameCtrl.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(L.t('my_id_title'))),
      body: uuid == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 이름을 설정해야 QR/코드가 나온다(빈 이름 공유 방지).
                  if (!hasName)
                    Center(
                      child: Container(
                        width: 268,
                        height: 268,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1F27),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.badge_outlined,
                                size: 40, color: Colors.white38),
                            const SizedBox(height: 12),
                            Text(
                              L.t('my_id_need_name'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SizedBox(
                          width: 240,
                          height: 240,
                          child: PrettyQrView.data(
                            data: _link,
                            decoration: const PrettyQrDecoration(
                              shape:
                                  PrettyQrSmoothSymbol(color: Color(0xFF000000)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _nameCtrl,
                    focusNode: _nameFocus,
                    textAlign: TextAlign.center,
                    maxLength: 20,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _nameFocus.unfocus(), // 확인 → 키보드 닫고 위로
                    decoration: InputDecoration(
                      labelText: L.t('display_name'),
                      hintText: L.t('my_id_name_hint'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      DeviceId.setName(v);
                      setState(() {}); // QR/링크에 이름 반영
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    L.t('my_id_desc'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  if (hasName) ...[
                    const SizedBox(height: 24),
                    // 짧은 코드(스캔 어려운 TV/태블릿용): 상대가 "코드로 추가"에 입력.
                    if (_code.isNotEmpty)
                      _CodeCard(
                        code: _code,
                        onCopy: () =>
                            _copy(_code, L.t('code_copied')),
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _shareLink,
                      icon: const Icon(Icons.share),
                      label: Text(L.t('share_my_link')),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _CodeCard extends StatelessWidget {
  final String code;
  final VoidCallback onCopy;
  const _CodeCard({required this.code, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F27),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L.t('my_code'),
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(height: 4),
              Text(
                code,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            onPressed: onCopy,
            icon: const Icon(Icons.copy),
            tooltip: L.t('copy'),
          ),
        ],
      ),
    );
  }
}
