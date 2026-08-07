import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'device_id.dart';
import 'friends.dart';
import 'l10n.dart';
import 'push_service.dart';

/// 내 ID QR 화면. 상대가 이 QR을 스캔하면 나를 친구추가/전화할 수 있다.
class MyIdScreen extends StatefulWidget {
  const MyIdScreen({super.key});
  @override
  State<MyIdScreen> createState() => _MyIdScreenState();
}

class _MyIdScreenState extends State<MyIdScreen> {
  final _nameCtrl = TextEditingController();
  String? _uuid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = await DeviceId.uuid();
    final nm = await DeviceId.name();
    if (!mounted) return;
    setState(() {
      _uuid = id;
      _nameCtrl.text = nm;
    });
  }

  @override
  void dispose() {
    // 편집한 이름을 기기 등록(Firestore)에도 반영 → 친구에게 새 이름으로 표시.
    PushService.instance.refreshDevice();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uuid = _uuid;
    return Scaffold(
      appBar: AppBar(title: Text(L.t('my_id_title'))),
      body: uuid == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                          data: IdPayload.encode(uuid, _nameCtrl.text.trim()),
                          decoration: const PrettyQrDecoration(
                            shape: PrettyQrSmoothSymbol(color: Color(0xFF000000)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _nameCtrl,
                    textAlign: TextAlign.center,
                    maxLength: 20,
                    decoration: InputDecoration(
                      labelText: L.t('display_name'),
                      hintText: L.t('my_id_name_hint'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      DeviceId.setName(v);
                      setState(() {}); // QR에 이름 반영
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    L.t('my_id_desc'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 20),
                  SelectableText(
                    'ID: $uuid',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Colors.white38),
                  ),
                ],
              ),
            ),
    );
  }
}
