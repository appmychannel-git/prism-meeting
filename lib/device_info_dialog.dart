import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'l10n.dart';
import 'mobile_auth.dart';
import 'store_login.dart';

/// CS 진단용 "기기·앱 정보" 상세 화면(버전 5탭 → 기기 검증 팝업 → 자세히).
/// 앱·기기·식별·로그인·네트워크 정보를 한 화면에 모아 보여주고, [전송]으로 서버에
/// 저장(접수번호)한다. 서버 미구현이면 전송만 실패하고 화면은 유지된다.
/// 규칙: md/subapp-device-info-guide-2026-10-16.md
Future<void> showDeviceInfoDialog(BuildContext context) async {
  final data = await _gather();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _DeviceInfoDialog(data: data),
  );
}

/// 수집한 값(표시 + 전송 공용).
class _Report {
  final Map<String, dynamic> device; // 네이티브 deviceReport
  final String packageName;
  final String appVersionName;
  final int appVersionCode;
  final String loginState;
  final String deviceAuth;
  final String installCond;
  final String serialMasked;
  final String serverDeviceId;
  _Report({
    required this.device,
    required this.packageName,
    required this.appVersionName,
    required this.appVersionCode,
    required this.loginState,
    required this.deviceAuth,
    required this.installCond,
    required this.serialMasked,
    required this.serverDeviceId,
  });
}

const _ch = MethodChannel('app/fullscreen');

Future<_Report> _gather() async {
  Map<String, dynamic> dev = {};
  try {
    final r = await _ch.invokeMethod<dynamic>('deviceReport');
    if (r is Map) dev = r.map((k, v) => MapEntry(k.toString(), v));
  } catch (_) {}

  String pkg = '';
  try {
    pkg = (await PackageInfo.fromPlatform()).packageName;
  } catch (_) {}

  // 로그인/인증: TV=마켓 세션, 모바일=viewplus 세션.
  String loginState = '-', deviceAuth = '-', installCond = '-', serverDevId = '-';
  final serialMasked = '-'; // 세션에 마스킹 시리얼이 없으면 '-'
  final info = await StoreLogin.read();
  if (info != null) {
    loginState = info.isValid ? L.t('di_logged_in') : L.t('di_logged_out');
    deviceAuth = info.registered ? L.t('di_verified') : L.t('di_unverified');
    installCond = info.downloadPolicy;
    serverDevId = info.deviceId.isNotEmpty ? info.deviceId : '-';
  } else {
    final logged = await MobileAuth.instance.hasSession();
    loginState = logged ? L.t('di_logged_in') : L.t('di_logged_out');
    final reg = MobileAuth.instance.user?.registered ?? false;
    deviceAuth = reg ? L.t('di_verified') : L.t('di_unverified');
    try {
      final sp = await SharedPreferences.getInstance();
      installCond = sp.getString('app_policy_value') ?? '-';
    } catch (_) {}
  }

  return _Report(
    device: dev,
    packageName: pkg,
    appVersionName: AppConfig.appVersion,
    appVersionCode: AppConfig.appVersionCode,
    loginState: loginState,
    deviceAuth: deviceAuth,
    installCond: installCond,
    serialMasked: serialMasked,
    serverDeviceId: serverDevId,
  );
}

class _DeviceInfoDialog extends StatefulWidget {
  const _DeviceInfoDialog({required this.data});
  final _Report data;

  @override
  State<_DeviceInfoDialog> createState() => _DeviceInfoDialogState();
}

class _DeviceInfoDialogState extends State<_DeviceInfoDialog> {
  bool _sending = false;

  String _s(String k, [String fallback = '-']) {
    final v = widget.data.device[k];
    final s = v?.toString() ?? '';
    return s.isEmpty ? fallback : s;
  }

  // 네이티브가 주는 연결 종류(한국어 고정값)를 화면 언어로. 전송 데이터는 그대로 둔다.
  String _netLabel(String v) {
    const keys = {
      '없음': 'di_net_none',
      '이더넷': 'di_net_ethernet',
      '모바일': 'di_net_mobile',
      '연결됨': 'di_net_connected',
      '확인 불가': 'di_net_unknown',
    };
    final k = keys[v];
    return k == null ? v : L.t(k);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final signHash = _s('signHash', '');
    final signShort =
        signHash.length > 12 ? '${signHash.substring(0, 12)}…' : signHash;
    final netOk = d.device['internetOk'] == true;

    return AlertDialog(
      backgroundColor: const Color(0xFF12161C),
      title: Text(L.t('di_title')),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header('[ ${L.t('di_sec_app')} ]'),
              _line(L.t('di_brand'), '${AppConfig.certBrand} / ${AppConfig.cuid}'),
              _line(L.t('di_package'), d.packageName),
              _line(L.t('di_version'), '${d.appVersionName} (${d.appVersionCode})'),
              _line(L.t('di_sign'), '${_s('sign')} ($signShort)'),
              _header('[ ${L.t('di_sec_device')} ]'),
              _line(L.t('di_manufacturer'), _s('manufacturer')),
              _line(L.t('di_model'), _s('model')),
              _line(L.t('di_devname'), _s('device')),
              _line('H/W S/N', _s('hwSerial')),
              _line(L.t('di_firmware'), _s('firmwareModel')),
              _line(L.t('di_build'), _s('buildId')),
              _line(L.t('di_android'), _s('androidVersion')),
              _line(L.t('di_screen'), _s('screen')),
              _header('[ ${L.t('di_sec_id')} ]'),
              _line('ANDROID_ID', _s('androidId')),
              _line(L.t('di_server_devid'), d.serverDeviceId),
              _header('[ ${L.t('di_sec_login')} ]'),
              _line(L.t('di_state'), d.loginState),
              _line(L.t('di_install_cond'), d.installCond),
              _line(L.t('di_device_auth'), d.deviceAuth),
              _line(L.t('di_serial'), d.serialMasked),
              _header('[ ${L.t('di_sec_net')} ]'),
              _line(L.t('di_conn'), _netLabel(_s('network'))),
              _line(L.t('di_internet'),
                  netOk ? L.t('di_net_ok') : L.t('di_net_no_internet')),
              _line('IP', _s('localIp')),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : _send,
          child: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(L.t('di_send')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L.t('ok')),
        ),
      ],
    );
  }

  static const _labelStyle =
      TextStyle(fontSize: 13, color: Colors.white54, height: 1.4);
  static const _valueStyle = TextStyle(
      fontSize: 13,
      color: Colors.white,
      height: 1.4,
      fontFamily: 'monospace');

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(t,
            style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF5B8DEF),
                fontWeight: FontWeight.bold)),
      );

  Widget _line(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 96, child: Text(k, style: _labelStyle)),
            const Text(':  ', style: _labelStyle),
            Expanded(child: SelectableText(v, style: _valueStyle)),
          ],
        ),
      );

  Future<void> _send() async {
    setState(() => _sending = true);
    final no = await _postReport(widget.data);
    if (!mounted) return;
    setState(() => _sending = false);
    final msg = (no != null)
        ? L.t('di_sent', {'no': no})
        : L.t('di_send_failed');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 전송: POST /api/tv/device-report. 성공 시 접수번호, 실패 시 null(차단하지 않음).
Future<String?> _postReport(_Report d) async {
  final body = <String, dynamic>{
    'app': AppConfig.policyAppCode,
    'brand': AppConfig.certBrand,
    'cuid': AppConfig.cuid,
    'packageName': d.packageName,
    'appVersionName': d.appVersionName,
    'appVersionCode': d.appVersionCode,
    'sign': d.device['sign'],
    'signHash': d.device['signHash'],
    'manufacturer': d.device['manufacturer'],
    'model': d.device['model'],
    'firmwareModel': d.device['firmwareModel'],
    'buildId': d.device['buildId'],
    'androidVersion': d.device['androidVersion'],
    'screen': d.device['screen'],
    'hwSerial': d.device['hwSerial'],
    'androidId': d.device['androidId'],
    'deviceId': d.serverDeviceId,
    'registered': d.deviceAuth,
    'serialMasked': d.serialMasked,
    'downloadPolicy': d.installCond,
    'network': '${d.device['network']}/'
        '${d.device['internetOk'] == true ? 'ok' : 'no'}',
    'localIp': d.device['localIp'],
  };
  try {
    final r = await http
        .post(
          Uri.parse('https://viewplus.co.kr/api/tv/device-report'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode == 200) {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['success'] == true && j['data'] is Map) {
        return (j['data']['reportNo'] ?? '').toString();
      }
    }
  } catch (_) {}
  return null;
}
